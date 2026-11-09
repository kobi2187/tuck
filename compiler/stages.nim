# compiler/stages.nim
#
# Stackless transform, phase 2 (#216, docs/stackless-concurrency.md): split a
# frame fn's body into STAGES at its pause points. Backend-neutral: it decides
# where the cuts go and what each stage ends with; a backend prints the plan
# (codegen_stages.nim for Nim), reusing its own statement emitter for the
# code between the cuts. Splitting is decided here, once, so the backends
# cannot disagree about where a task pauses.
#
# It runs on a backend's lowered, mangled copy, just before printing, so it
# sees the simple statements lowering leaves behind.
#
# THE CUTS keep today's stackful semantics:
#   * in a TASK body, an [io] call yields first and then calls. The yield
#     goes before the STATEMENT holding the call: the statement has not
#     started, so nothing observable moves across it;
#   * a call to a frame fn ends the stage; the caller resumes in the next
#     one, reading the result the callee wrote through its destination;
#   * a binding that awaits a task ends the stage; the next one starts by
#     taking the value out of the task's slot;
#   * an `if` whose branches pause becomes a branch to two stage chains that
#     meet at a join stage; a `match` whose arms pause is the backend's own
#     `case`, each arm body replaced by a JUMP to that arm's chain;
#   * a loop whose body pauses keeps its iteration state in the frame (a
#     counter and an end, or an index over a Seq) and runs as head, body and
#     step stages; `break` and `continue` in it become jumps.
#
# SCOPES. A stage's return is not a scope exit, so each split list that is a
# scope (a branch, an arm, a loop body, a block) gets an id, and its `defer`s
# are ARMED by flags in the frame. Every jump that leaves a scope names the
# scopes it leaves; the backend runs their armed `defer`s, innermost first.
# The frame's end runs whatever is still armed.
#
# JUMPS are the one thing a backend prints in place of a statement: a
# `break`/`continue` inside a split loop, or a match arm's body, each mapped
# (by node identity) to a target stage and the scopes it leaves.
#
# A pause inside `on select` or `defer` is phase 4: refused by name.
import std/[tables, sets, strutils, hashes]
import ast, ast_ops, ast_query, resolution, concurrency
from typecheck_util import typeName

type
  TermKind* = enum
    tkFall    ## the body's end: a void frame finishes
    tkGoto    ## continue in `next`, directly
    tkYield   ## requeue, continue in `next`
    tkBranch  ## `if cond`: `thenS`, else `elseS`
    tkCall    ## call frame fn `call`, continue in `next`
    tkAwait   ## spawn task `call` into slot field `slot`, park until done
    tkLoopEnter ## start loop `loop`: set its state, then body or exit
    tkLoopNext  ## advance loop `loop`: step its state, then body or exit

  LoopKind* = enum
    lkRange   ## `for i in a .. b` / `a ..< b`: counter + end in the frame
    lkSeq     ## `for x in xs`, xs a named Seq: an index; x views xs[index]
    lkWhile   ## `for cond:` / `loop:`: re-test at the head stage

  Loop* = object
    kind*: LoopKind
    node*: Expr             ## the exkFor / exkWhile
    varName*: string        ## lkRange: the counter field; lkSeq: the element alias
    stateField*: string     ## lkRange: the end field; lkSeq: the index field
    elemType*: Type         ## lkSeq: the element type (a backend with no
                            ## view to alias copies the element instead)
    head*, body*, exit*: int ## head: the step (`continue` lands there; for
                             ## lkWhile, the re-test); body; after the loop

  Jump* = object
    target*: int
    leaves*: seq[int]       ## scope ids this jump leaves, innermost first
  Term* = object
    kind*: TermKind
    next*, thenS*, elseS*: int
    cond*: Expr
    call*: Expr             ## tkCall / tkAwait: the call node
    callee*: Decl           ## tkCall / tkAwait: the frame decl it reaches
    target*: Expr           ## where the result goes; nil: nowhere
    slot*: string           ## tkAwait: the frame field holding the slot
    leaves*: seq[int]       ## tkGoto: scope ids it leaves, innermost first
    loop*: int              ## tkLoopEnter / tkLoopNext: index into loops

  Stage* = object
    stmts*: seq[Expr]
    term*: Term

  FrameField* = object
    name*: string
    typ*: Type
    isSlot*: bool           ## a task slot: `typ` is the TASK's result type

  StagePlan* = object
    stages*: seq[Stage]     ## stage 0 is the entry
    defers*: seq[Expr]      ## the `defer`s of the lists that are split, in
                            ## order. A stage's return is not a scope exit,
                            ## so each is ARMED by a flag in the frame
                            ## (`tuckDeferK`) and run at its scope's real
                            ## exit: a branch's jump out, or the frame's end.
    fields*: seq[FrameField] ## the locals that live in the frame (params not included)
    scopeDefers*: seq[seq[int]] ## per scope id: the defers it arms, in order
    loops*: seq[Loop]
    jumps*: Table[Expr, Jump] ## by node identity: what to print instead
    error*: string          ## non-empty: this body uses a shape not built yet

  Splitter = object
    res: Resolution
    m: Module
    isTask: bool
    plan: StagePlan
    fieldIdx: Table[string, int]
    open: seq[int]          ## the scope ids open here, outermost first
    loopStack: seq[tuple[loop, depth: int]] ## split loops open here, and the
                            ## `open` depth of each one's body scope
    awaited: HashSet[NodeId] ## task calls a binding awaits; an unbound one
                             ## only spawns, which is not a pause

const Nested = {exkIf, exkMatch, exkFor, exkWhile, exkBlock, exkSelect, exkDefer}

proc hash*(e: Expr): Hash = hash(cast[pointer](e))
  ## Jumps are keyed by node IDENTITY: two `break`s are equal by value.

# --- what a node is ------------------------------------------------------------

proc callOf(sp: Splitter, n: Expr): Expr =
  if n.kind == exkCall: n
  elif sp.res.hasCall(n): sp.res.call(n)
  else: nil

proc frameCallee(sp: Splitter, c: Expr): Decl =
  ## The frame decl a call reaches when the call pauses on it: a frame fn,
  ## or a task whose result is bound. Nil otherwise.
  let d = calleeDecl(sp.res, sp.m, c)
  if d == nil or not d.id.isSet or d.id notin frameDecls: return nil
  if d.kind == dkTask and not (c.id.isSet and c.id in sp.awaited): return nil
  d

proc noteAwaits(sp: var Splitter, body: Expr) =
  for n in body.nodes:
    if n.kind == exkAssign and n.assignVal != nil and n.assignVal.kind == exkCall and
       n.assignVal.id.isSet:
      sp.awaited.incl n.assignVal.id

proc yieldsAt(sp: Splitter, n: Expr): bool =
  ## Does the task body yield before this node's statement?
  if not sp.isTask: return false
  let c = sp.callOf(n)
  c != nil and sp.res.isAsync(c)

proc isPause(sp: Splitter, n: Expr): bool =
  ## Any pause at this node: a yield, a frame call or task await, a select.
  if n.kind == exkSelect or sp.yieldsAt(n): return true
  let c = sp.callOf(n)
  c != nil and sp.frameCallee(c) != nil

proc pausesIn(sp: Splitter, e: Expr): bool =
  if e == nil: return false
  for n in e.nodes:
    if sp.isPause(n): return true

proc framePausesIn(sp: Splitter, e: Expr): bool =
  ## A pause other than a yield: a frame call, a task await, a select.
  if e == nil: return false
  for n in e.nodes:
    if sp.isPause(n) and not sp.yieldsAt(n): return true

proc yieldCount(sp: Splitter, e: Expr): int =
  for n in e.nodes:
    if sp.yieldsAt(n): inc result

# --- stages and fields -----------------------------------------------------------

proc newStage(sp: var Splitter): int =
  sp.plan.stages.add Stage(term: Term(kind: tkFall))
  sp.plan.stages.high

proc fail(sp: var Splitter, n: Expr, what: string) =
  if sp.plan.error == "":
    sp.plan.error = "line " & $n.span.line & ": " & what &
                    " is not supported by --concurrency:stackless yet (#216)"

proc addField(sp: var Splitter, n: Expr, name: string, t: Type, isSlot = false) =
  if name in sp.fieldIdx:
    if not isSlot and typeName(sp.plan.fields[sp.fieldIdx[name]].typ) != typeName(t):
      sp.fail(n, "two locals named '" & name & "' with different types")
    return
  if t == nil: sp.fail(n, "a local whose type is unknown ('" & name & "')")
  sp.fieldIdx[name] = sp.plan.fields.len
  sp.plan.fields.add FrameField(name: name, typ: t, isSlot: isSlot)

proc noteLocal(sp: var Splitter, s: Expr) =
  ## A local declared in a list that is split lives in the frame.
  if s.kind != exkAssign or not s.isDecl or s.target == nil or s.target.kind != exkVar:
    return
  var t = sp.res.typeFor(s.target)
  if t == nil: t = sp.res.typeFor(s.assignVal)
  sp.addField(s, s.target.name, t)

# --- one statement ----------------------------------------------------------------

proc valueCall(s: Expr): tuple[call, target: Expr] =
  ## The call a simple statement IS (`f x`, `discard f x`, `x = f y`), with
  ## where its value goes.
  case s.kind
  of exkCall: (s, nil)
  of exkDiscard: (s.discardVal, nil)
  of exkAssign: (s.assignVal, s.target)
  else: (nil, nil)

proc endWith(sp: var Splitter, cur: int, t: Term): int =
  ## End stage `cur` with `t`, continuing in a fresh stage.
  result = sp.newStage()
  var t = t
  t.next = result
  sp.plan.stages[cur].term = t

proc emitYields(sp: var Splitter, cur: var int, n: int) =
  for _ in 0 ..< n: cur = sp.endWith(cur, Term(kind: tkYield))

proc callTerm(sp: var Splitter, s: Expr, c: Expr, callee: Decl, target: Expr): Term =
  if callee.kind == dkTask:
    let slot = "tuckSlot" & $sp.plan.fields.len
    sp.addField(s, slot, callee.fnReturnType, isSlot = true)
    Term(kind: tkAwait, call: c, callee: callee, target: target, slot: slot)
  else:
    Term(kind: tkCall, call: c, callee: callee, target: target)

proc simpleStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## A statement with no nested body: yields before it, then it runs, or it
  ## IS a frame call / task await that ends the stage.
  sp.emitYields(cur, sp.yieldCount(s))
  let (v, target) = valueCall(s)
  let c = if v != nil: sp.callOf(v) else: nil
  let callee = if c != nil: sp.frameCallee(c) else: nil
  if callee == nil:
    for n in s.nodes:
      if n.kind != exkCall and sp.callOf(n) != nil and sp.frameCallee(sp.callOf(n)) != nil:
        sp.fail(s, "a frame call inside a larger expression")
    sp.plan.stages[cur].stmts.add s
  else:
    sp.noteLocal(s)
    cur = sp.endWith(cur, sp.callTerm(s, c, callee, target))

proc splitList(sp: var Splitter, stmts: seq[Expr], cur: var int)

# --- scopes and jumps -------------------------------------------------------------

proc openScope(sp: var Splitter): int =
  result = sp.plan.scopeDefers.len
  sp.plan.scopeDefers.add @[]
  sp.open.add result

proc leaving(sp: Splitter, depth: int): seq[int] =
  ## The open scopes from `depth` in, innermost first: what a jump out of
  ## them leaves.
  for i in countdown(sp.open.high, depth): result.add sp.open[i]

proc chain(sp: var Splitter, body: Expr, next: int): int =
  ## A scope's stage chain: its statements, then a jump to `next` that
  ## leaves the scope.
  result = sp.newStage()
  var cur = result
  let depth = sp.open.len
  discard sp.openScope()
  if body != nil:
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: next, leaves: sp.leaving(depth))
  sp.open.setLen depth

proc jumpsIn(sp: var Splitter, e: Expr) =
  ## Every `break`/`continue` of the innermost split loop inside `e`, which
  ## the backend prints itself (an inline `if`): each becomes a jump. A
  ## loop nested in `e` is native and keeps its own.
  if e == nil or sp.loopStack.len == 0: return
  if e.kind in {exkFor, exkWhile}: return
  if e.kind in {exkBreak, exkContinue}:
    let (k, depth) = sp.loopStack[^1]
    let lp = sp.plan.loops[k]
    # `break` leaves for the exit; `continue` for the step (`head`), which
    # re-tests a `for cond:` and advances a counted loop.
    sp.plan.jumps[e] = Jump(target: (if e.kind == exkBreak: lp.exit else: lp.head),
                            leaves: sp.leaving(depth))
    return
  for c in e.children: sp.jumpsIn(c)

# --- if, match, block -------------------------------------------------------------

proc ifStmt(sp: var Splitter, cur: var int, s: Expr) =
  sp.emitYields(cur, sp.yieldCount(s.cond))
  let join = sp.newStage()
  let thenS = sp.chain(s.thenBranch, join)
  let elseS = sp.chain(s.elseBranch, join)
  sp.plan.stages[cur].term = Term(kind: tkBranch, cond: s.cond, thenS: thenS, elseS: elseS)
  cur = join

proc matchStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## The backend prints its own `case` on the subject; each arm's body is a
  ## jump carrier sending control to that arm's chain.
  if sp.framePausesIn(s.subject): sp.fail(s, "a frame call in a match subject")
  sp.emitYields(cur, sp.yieldCount(s.subject))
  let join = sp.newStage()
  var arms: seq[MatchArm]
  for arm in s.arms:
    let carrier = Expr(kind: exkBreak, span: arm.span)
    sp.plan.jumps[carrier] = Jump(target: sp.chain(arm.body, join))
    arms.add MatchArm(pattern: arm.pattern, span: arm.span,
                      body: Expr(kind: exkBlock, stmts: @[carrier], span: arm.span))
  sp.plan.stages[cur].stmts.add Expr(kind: exkMatch, subject: s.subject, arms: arms,
                                     span: s.span, id: s.id)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: join)   # not reached: every arm jumps
  cur = join

proc blockStmt(sp: var Splitter, cur: var int, s: Expr) =
  ## A nested block is a scope of its own, entered directly.
  let join = sp.newStage()
  let entry = sp.chain(s, join)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: entry)
  cur = join

# --- loops ------------------------------------------------------------------------

proc intType(): Type = Type(kind: tkNamed, name: "int")

proc loopKind(sp: var Splitter, s: Expr): LoopKind =
  if s.kind == exkWhile: return lkWhile
  if s.iter == nil or s.iter.kind != pkVar:
    sp.fail(s, "a destructuring `for` whose body pauses")
  let it = s.iterable
  if it.kind == exkBinary and it.binOp in {boRangeIncl, boRangeExcl}: return lkRange
  if it.kind != exkVar: sp.fail(s, "a `for` over a computed sequence whose body pauses")
  lkSeq

proc loopState(sp: var Splitter, s: Expr, kind: LoopKind, k: int): Loop =
  result = Loop(kind: kind, node: s)
  case kind
  of lkRange:
    result.varName = s.iter.name
    result.stateField = "tuckEnd" & $k
    var t = sp.res.typeFor(s.iterable.left)
    if t == nil: t = intType()
    sp.addField(s, result.varName, t)
    sp.addField(s, result.stateField, t)
  of lkSeq:
    result.varName = s.iter.name
    result.stateField = "tuckIdx" & $k
    result.elemType = seqElem(sp.res.typeFor(s.iterable))
    sp.addField(s, result.stateField, intType())
  of lkWhile: discard

proc whileHead(sp: var Splitter, k: int, s: Expr) =
  ## A `for cond:` re-tests at its head, yielding first for an [io] call in
  ## the condition, every iteration; a `loop:` just goes round.
  if s.whileCond != nil and sp.framePausesIn(s.whileCond):
    sp.fail(s, "a frame call in a loop condition")
  var head = sp.plan.loops[k].head
  if s.whileCond != nil: sp.emitYields(head, sp.yieldCount(s.whileCond))
  let lp = sp.plan.loops[k]
  sp.plan.stages[head].term =
    if s.whileCond == nil: Term(kind: tkGoto, next: lp.body)
    else: Term(kind: tkBranch, cond: s.whileCond, thenS: lp.body, elseS: lp.exit)

proc loopBody(sp: var Splitter, k: int, s: Expr) =
  ## The body: a scope of its own, entered at `body`, ending in the step.
  let depth = sp.open.len
  sp.loopStack.add (k, depth)
  var cur = sp.plan.loops[k].body
  discard sp.openScope()
  let body = if s.kind == exkWhile: s.whileBody else: s.body
  if body != nil:
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan.stages[cur].term = Term(kind: tkGoto, next: sp.plan.loops[k].head,
                                  leaves: sp.leaving(depth))
  sp.open.setLen depth
  discard sp.loopStack.pop()

proc loopStmt(sp: var Splitter, cur: var int, s: Expr) =
  let kind = sp.loopKind(s)
  if kind != lkWhile:
    if sp.framePausesIn(s.iterable): sp.fail(s, "a frame call in a loop's range")
    sp.emitYields(cur, sp.yieldCount(s.iterable))
  let k = sp.plan.loops.len
  sp.plan.loops.add sp.loopState(s, kind, k)
  sp.plan.loops[k].head = sp.newStage()
  sp.plan.loops[k].exit = sp.newStage()
  sp.plan.loops[k].body = sp.newStage()
  if kind == lkWhile: sp.whileHead(k, s)
  else: sp.plan.stages[sp.plan.loops[k].head].term = Term(kind: tkLoopNext, loop: k)
  sp.loopBody(k, s)
  sp.plan.stages[cur].term =
    if kind == lkWhile: Term(kind: tkGoto, next: sp.plan.loops[k].head)
    else: Term(kind: tkLoopEnter, loop: k)
  cur = sp.plan.loops[k].exit

# --- one statement ----------------------------------------------------------------

proc deferStmt(sp: var Splitter, cur: int, s: Expr) =
  ## A `defer` arms an exit action, run when its scope is left: by a jump
  ## out of it, or by the frame's end.
  if sp.pausesIn(s.deferBody): sp.fail(s, "a pause inside a `defer`")
  if sp.open.len > 0: sp.plan.scopeDefers[sp.open[^1]].add sp.plan.defers.len
  sp.plan.defers.add s
  sp.plan.stages[cur].stmts.add s

proc branchesPause(sp: Splitter, s: Expr): bool =
  sp.pausesIn(s.thenBranch) or sp.pausesIn(s.elseBranch)

proc inline(sp: var Splitter, cur: int, s: Expr) =
  ## A statement the backend prints as it is; its loop jumps become jumps.
  sp.jumpsIn(s)
  sp.plan.stages[cur].stmts.add s

proc nestedStmt(sp: var Splitter, cur: var int, s: Expr) =
  case s.kind
  of exkIf:
    if sp.branchesPause(s): sp.ifStmt(cur, s)
    elif sp.framePausesIn(s.cond): sp.fail(s, "a frame call in an `if` condition")
    else:
      sp.emitYields(cur, sp.yieldCount(s.cond))   # only the condition yields
      sp.inline(cur, s)
  of exkMatch: sp.matchStmt(cur, s)
  of exkFor, exkWhile: sp.loopStmt(cur, s)
  of exkBlock: sp.blockStmt(cur, s)
  else: sp.fail(s, "a pause inside " & ($s.kind)[3 .. ^1].toLowerAscii)

proc splitStmt(sp: var Splitter, cur: var int, s: Expr) =
  sp.noteLocal(s)
  if s.kind == exkDefer: sp.deferStmt(cur, s)
  elif not sp.pausesIn(s): sp.inline(cur, s)
  elif s.kind in Nested: sp.nestedStmt(cur, s)
  else: sp.simpleStmt(cur, s)

proc splitList(sp: var Splitter, stmts: seq[Expr], cur: var int) =
  for s in stmts: sp.splitStmt(cur, s)

proc planStages*(res: Resolution, m: Module, d: Decl): StagePlan =
  ## The stages of frame fn or task `d` (its lowered, mangled copy).
  var sp = Splitter(res: res, m: m, isTask: d.kind == dkTask)
  var cur = sp.newStage()
  let body = d.fnBody
  if body != nil:
    sp.noteAwaits(body)
    discard sp.openScope()          # scope 0: the body, left only at the end
    sp.splitList(if body.kind == exkBlock: body.stmts else: @[body], cur)
  sp.plan
