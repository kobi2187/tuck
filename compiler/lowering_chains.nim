# compiler/lowering_chains.nim
#
# `..` CHAINS, LOWERED (ROADMAP M4.5) — every chain becomes the statements it
# means before any backend sees it.
#
#     server ..withDefaults ..port {8080}
#
# is a builder: each step reassigns the base, and a value with an
# `invariant:` block is checked once, after the last step. As statements:
#
#     server = withDefaults(server)
#     server.port = 8080               # inChain: not validated on its own
#     validate(server)                 # exkValidate, when there are invariants
#
# A chain whose VALUE is used runs on a copy and leaves its base alone —
# `let t = a ..setN {5}` reads `a` and does not write it:
#
#     var tuckChainN = a
#     tuckChainN = setN(tuckChainN, 5)
#     let t = tuckChainN
#
# The same holds for a chain fed straight into a call (`self ..load {n}
# .start`), which is where this began: `hoistChainCalls` lowered that one
# shape, and each backend lowered the rest itself at emit time — the three
# had already drifted once (Odin wrote a bound chain's temp back through the
# base, a different program from Nim's and D's).
#
# The step's call is the one the checker resolved (`res.stepCall`), and it
# is COPIED with fresh ids before it goes into the tree. That table is shared
# by every backend — the three trees are copies, the table is not — so a pass
# that edits a node in place (explodePayload, lowering_strtemps) must never
# be handed one of its nodes: the edit would reach the next backend's tree.
#
# Nothing downstream sees an `exkChain`: `pipeline.assertChainsLowered`
# checks every lowered tree for one.
import ast, ast_ops, ast_query
import resolution

var tmpCounter = 0

proc freshTemp(sp: Span): string =
  inc tmpCounter
  "tuckChain" & $tmpCounter

proc rethreadCall(res: Resolution, call: Expr, oldId: NodeId,
                  replacement: Expr): Expr =
  ## A FRESH copy of `call` — new ids, the checker's facts carried over —
  ## with the argument whose id is `oldId` replaced. Never mutates `call`: it
  ## came from `res.stepCall`/`res.call`, shared by every backend.
  ##
  ## The base need not be there at all: the optimizer splices a builder's
  ## body into its step (`..withDefaults` becomes the record it builds), and
  ## it only does so when that body does not read the receiver.
  if call == nil: return nil
  result = res.freshCopy(call)
  if call.kind != exkCall: return
  for i in 0 ..< call.args.len:
    if call.args[i] != nil and call.args[i].id == oldId:
      result.args[i] = replacement

proc stepMember(step: ChainStep): string =
  ## The member a `..` step names: a bare name, or `mod::fn`, whose target is
  ## an exkQualified node — reading `.name` off that is a FieldDefect.
  case step.target.kind
  of exkVar: step.target.name
  of exkQualified: step.target.qualName
  else: raiseAssert "lowering_chains: a step names a " & $step.target.kind

proc stepStmts(res: Resolution, m: Module, chain: Expr,
               into: Expr): seq[Expr] =
  ## The chain's steps as statements writing through `into` — the base
  ## itself for a builder, a temp for a chain whose value is used. `into` is
  ## a template: each use is a fresh copy, since one node may sit in one
  ## place only.
  for step in chain.steps:
    let sc = res.stepCall(step)
    if sc != nil:
      result.add Expr(span: step.span, kind: exkAssign,
                      target: res.freshCopy(into),
                      assignVal: rethreadCall(res, sc, chain.base.id,
                                              res.freshCopy(into)))
    else:
      # `..field {v}`: set one field. Validated with the whole chain, at its
      # end — the intermediate states of a builder need not hold the
      # invariant, the value it builds must.
      let target = Expr(span: step.span, kind: exkField,
                        receiver: res.freshCopy(into),
                        fieldName: stepMember(step))
      let value = if isSingleFieldPayload(step.arg): soleFieldValue(step.arg)
                  else: step.arg
      result.add Expr(span: step.span, kind: exkAssign, target: target,
                      assignVal: value, inChain: true)
  let t = res.typeFor(chain.base)
  if t != nil and t.kind == tkNamed and hasInvariants(m, t.name):
    result.add Expr(span: chain.span, kind: exkValidate,
                    validated: res.freshCopy(into))

proc builderStmts(res: Resolution, m: Module, chain: Expr): seq[Expr] =
  ## A chain standing alone: it updates its base.
  stepStmts(res, m, chain, chain.base)

proc valueStmts(res: Resolution, m: Module, chain: Expr): (seq[Expr], Expr) =
  ## A chain whose value is used: run it on a temp seeded from the base, and
  ## hand back the statements and a read of the temp.
  let name = freshTemp(chain.span)
  let t = res.typeFor(chain.base)
  let tmp = Expr(span: chain.span, kind: exkVar, name: name)
  res.setType(tmp, t)
  var stmts = @[Expr(span: chain.span, kind: exkAssign, target: tmp,
                     assignVal: chain.base, isDecl: true, isMutable: true)]
  stmts.add stepStmts(res, m, chain, tmp)
  (stmts, res.freshCopy(tmp))

proc chainOnFieldCall(res: Resolution, e: Expr): bool =
  ## `self ..loadEpisode {n} .startAudio` — a resolved `.fn` call whose
  ## receiver is a chain.
  e != nil and e.kind == exkField and e.receiver != nil and
    e.receiver.kind == exkChain and res.hasCall(e)

proc returnsValue(retType: Type): bool =
  retType != nil and not (retType.kind == tkNamed and retType.name == "void")

proc lowerStmt(res: Resolution, m: Module, s: Expr,
               tailOf: Type): seq[Expr] =
  ## One statement's replacement, or @[s] when it holds no chain this pass
  ## lowers. `tailOf` is the enclosing fn's return type when `s` is the last
  ## statement of its body, else nil.
  if s == nil: return @[s]
  if s.kind == exkChain:
    result = builderStmts(res, m, s)
    # A chain ending a fn that returns a value IS the value: the base, as
    # the steps left it. (It was injectTailReturn's job, at emit time.)
    if returnsValue(tailOf):
      result.add Expr(span: s.span, kind: exkReturn,
                      returnVal: res.freshCopy(s.base))
    return
  if chainOnFieldCall(res, s):
    let (stmts, tmp) = valueStmts(res, m, s.receiver)
    result = stmts
    result.add rethreadCall(res, res.call(s), s.receiver.id, tmp)
    return
  if s.kind == exkAssign and s.assignVal != nil and s.assignVal.kind == exkChain:
    let (stmts, tmp) = valueStmts(res, m, s.assignVal)
    s.assignVal = tmp
    return stmts & @[s]
  if s.kind == exkReturn and s.returnVal != nil and s.returnVal.kind == exkChain:
    let (stmts, tmp) = valueStmts(res, m, s.returnVal)
    s.returnVal = tmp
    return stmts & @[s]
  @[s]

proc lowerBlock(res: Resolution, m: Module, b: Expr, retType: Type)

proc asBody(e: Expr): Expr =
  ## A branch or loop body that is a single chain gets a block for its
  ## statements to go into.
  if e != nil and (e.kind == exkChain or
                   (e.kind == exkField and e.receiver != nil and
                    e.receiver.kind == exkChain)):
    Expr(span: e.span, kind: exkBlock, stmts: @[e])
  else: e

proc lowerNested(res: Resolution, m: Module, e: Expr) =
  ## Every block below `e`, each lowered within itself. A nested block is not
  ## a fn body, so no statement in it is the fn's tail value.
  if e == nil: return
  case e.kind
  of exkBlock:
    lowerBlock(res, m, e, nil)
    return
  of exkIf:
    e.thenBranch = asBody(e.thenBranch)
    e.elseBranch = asBody(e.elseBranch)
  of exkMatch:
    for arm in e.arms.mitems: arm.body = asBody(arm.body)
  of exkWhile: e.whileBody = asBody(e.whileBody)
  of exkFor: e.body = asBody(e.body)
  of exkDefer: e.deferBody = asBody(e.deferBody)
  else: discard
  for ch in e.children: lowerNested(res, m, ch)

proc lowerBlock(res: Resolution, m: Module, b: Expr, retType: Type) =
  var stmts: seq[Expr]
  for i, s in b.stmts:
    let tail = if i == b.stmts.high: retType else: nil
    for r in lowerStmt(res, m, s, tail):
      lowerNested(res, m, r)
      stmts.add r
  b.stmts = stmts

proc lowerBody(res: Resolution, m: Module, body: Expr, retType: Type): Expr =
  ## A fn body. One that is a bare chain rather than a block gets a block to
  ## hold its statements; any other bare expression is left as it is.
  result = asBody(body)
  if result == nil: return
  if result.kind == exkBlock: lowerBlock(res, m, result, retType)
  else: lowerNested(res, m, result)

proc lowerChains*(res: Resolution, m: Module) =
  ## Every chain in the module's bodies. A body that runs as STATEMENTS — a
  ## fn's, a task's, an `on select` arm's — may itself be a bare chain and
  ## gets a block to hold what it becomes; any other (a const's value, an
  ## initialiser) is a value, lowered where it stands.
  for d in m.allDecls:
    if d.kind == dkFn:
      d.fnBody = lowerBody(res, m, d.fnBody, d.fnReturnType)
    elif d.kind == dkTask:
      d.taskBody = lowerBody(res, m, d.taskBody, d.taskReturnType)
    elif d.kind == dkSelect:
      for arm in d.selectArms.mitems:
        lowerNested(res, m, arm.arg)
        arm.body = lowerBody(res, m, arm.body, nil)
    else:
      for e in d.ownExprs: lowerNested(res, m, e)
