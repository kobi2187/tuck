# compiler/ownership_nodes.nim
#
# OWNERSHIP DECISIONS, MADE INTO NODES — Stage C of the ownership rules
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §8).
#
# The rules say every read is a borrow or a sink, and every owned place is
# dropped once. Today those decisions are spread over predicates the
# emitters ask while they print — "is this assignment an append?", "does
# this binding need a copy?", "free the old value here?" — so the decision
# exists only in the string a backend built, where nothing after it can see
# it and three backends each re-derive it their own way. Stage C turns each
# decision into an AST node the pass makes once and every emitter prints.
# Stage D made the same nodes from the rules instead, and today's predicates
# are gone.
#
# FIRST NODE: `exkAppend` — `xs += v`, a container grown in place.
#
#   `xs = {items: xs, value: v} push`  an append assigned back over its own
#                                     argument (ast_query.selfAppendValue)
#   `s = s + t` on a str              a concat assigned back over its own LEFT
#                                     operand (ast_query.selfConcatValue) — on
#                                     a backend whose strings grow in place
#
# Both are rule S at the one place it is syntactic: the old value is dead the
# instant the new one lands, so its last read is a SINK into the new value,
# and a sink into a value built from it is a growth in place. The emitters
# used to recognise both shapes while printing (Nim twice, D twice, Odin
# once); the decision now lives here and they print `exkAppend`.
#
# RUNS LAST in `backend_prepare`, after every pass that reads the assignment
# it replaces (the twin marks). The node keeps the assignment's id, so every fact recorded against
# the statement — its type (void), a shortcut site — stays attached.
#
# SECOND NODE: `exkCopy` — a value copied where it is put to a sink that is
# not its place's final use (rule S, `ownership_write`). What the copy is,
# is rule G's (`ownership_elab.copyKindOf`):
#
#   cpSeq     a `Seq` of plain values: one new buffer
#   cpDeep    anything else that owns storage: a deep copy (`rt.tuckCopy`)
#   cpStatic  a `str` (Odin): its bytes on the heap, so an owner may free it
#
# On every backend's tree; Nim prints a copy as its value (its assignment
# copies by itself), D a `str` copy as the `str` (immutable there).
#
# THIRD NODE: `exkDrop` — release what a place owns, printed by the backend
# that frees by hand (Odin) and as nothing by ARC (Nim) and the collector
# (D), placed from
# the rules' `DropSource` (`ownership_write.rulesDrops`):
#
#   scope end    `defer drop(x.slot)` as the statements after the one that
#                DECLARES `x`
#   overwrite    the assignment's own `dropsOld`: drop-and-replace, because
#                the old value dies after the new one is built and before it
#                is stored
#   parameter    `defer drop(p.slot)` at the top of a body that consumes
#                its parameter (rule P)
#
# "The one that declares x" is the statement the Odin emitter prints with
# `:=`: the first assignment to the name in its scope, where `for`/`while`
# bodies and `if` branches are scopes (genIndented restores the defined
# names after each) and the fn's parameters are defined already. The walk
# below follows the same rule, so a drop lands where it was printed.
#
# IT SAYS SO. The SSA cache asserts a body's shape has not changed since its
# lowered graph was built; a pass that rewrites a body after that must drop
# the graph, or the next fetch fails as "a pass rewrote it without saying
# so". No consumer fetches the lowered graph after this pass today; dropping
# it keeps that true by construction rather than by luck.
import tables, sets
import ast, ast_ops, ast_query
import resolution
import ssa_ir
import twin_calls

proc materializeAppend(n: Expr, parts: tuple[read, value: Expr],
                       element: bool) =
  ## `n` becomes `target += value`, IN PLACE: the node object keeps its
  ## position in every parent, and its id.
  ##
  ## THE TARGET IS THE READ, not the assignment's target. `xs += v` both reads
  ## and writes `xs`, and every fact about the read — that it is `xs`'s final
  ## use, that `xs` is an actor's field — was recorded against the READ node
  ## (`items: xs`, or the concat's left operand), keyed by its id. Keeping the
  ## write node instead dropped the final-use stamp with the payload it sat
  ## in, and Nim's `sink` inference (codegen_common.keptAt) stopped seeing
  ## `std/string`'s `add` keep its `text`.
  n[] = Expr(span: n.span, id: n.id, sourceName: n.sourceName,
             kind: exkAppend, appendTarget: parts.read,
             appendValue: parts.value, appendsElement: element)[]

proc materialize(res: Resolution, n: Expr): bool =
  ## Rewrites `n` if it is an append assigned back over its own argument.
  let pushed = selfAppendParts(res, n)
  if pushed.value != nil:
    materializeAppend(n, pushed, element = true)
    return true
  let concatenated = selfConcatParts(res, n)
  if concatenated.value == nil: return false
  materializeAppend(n, concatenated, element = false)
  true

proc materializeAppends*(res: Resolution, m: Module) =
  ## Every append assigned back over its own argument becomes `exkAppend`.
  ## `strGrows`: the backend's `str` grows in place (Nim, D — not Odin, whose
  ## strings are a pointer and a length, so `s = s + t` stays a concat and a
  ## free of the old value).
  for d in m.allDecls:
    var changed = false
    for body in d.ownExprs:
      if body == nil: continue
      for n in body.nodes:
        if n.kind == exkAssign and materialize(res, n):
          changed = true
    if changed and d.id.isSet:
      res.ssaGraphs.del((d.id, ssLowered))

proc dropOf(name, slot: string, span: Span, deep = false): Expr =
  ## `defer drop(name.slot)` — the place as a path ("" slot: the whole value).
  var place = Expr(span: span, kind: exkVar, name: name)
  if slot.len > 0:
    place = Expr(span: span, kind: exkField, receiver: place, fieldName: slot)
  let drop = Expr(span: span, kind: exkDrop, dropped: place, dropDeep: deep)
  result = Expr(span: span, kind: exkDefer, deferReleases: true,
                deferBody: Expr(span: span, kind: exkBlock, stmts: @[drop]))
  fillIdsIn(result)     # every node after prepare has one (assertTreeIds)

type DropSource* = object
  ## One body's drops, as the rules decided them (ownership_write).
  atScopeExit*: Table[string, seq[string]]
    ## owned place -> the slots dropped where its scope ends
  overwriteDrops*: HashSet[NodeId]
    ## the assignments that drop the value they replace
  paramDrops*: seq[tuple[param, slot: string]]
    ## parameter slots the body owns, dropped at its every exit
  deep*: HashSet[string]
    ## `place & "\t" & slot` of each slot whose drop walks it (rule G)
  deepOverwrites*: HashSet[NodeId]
    ## the overwrites whose old value is walked when it is dropped (rule G)

type DropWalk = object
  res: Resolution
  src: DropSource
  tasks: HashSet[string]

proc bindsTaskArgs(w: DropWalk, n: Expr): bool =
  ## `let r = {args} someTask` — printed by its own path, which frees nothing.
  let v = n.assignVal
  v != nil and v.kind == exkCall and v.callee != nil and
    v.callee.kind == exkVar and v.callee.name in w.tasks and v.args.len > 0

proc deepAt(w: DropWalk, name, slot: string): bool =
  ## Does this slot's drop walk it (rule G)?
  name & "\t" & slot in w.src.deep

proc fieldDropsOld(w: DropWalk, n: Expr): bool =
  ## An overwrite of one field (`b.items = v`): only the rules drop there.
  n.target.kind == exkField and n.id in w.src.overwriteDrops

proc dropsOldOf(w: DropWalk, n: Expr): bool =
  ## Does this overwrite drop the value it replaces? Decided by the rules,
  ## per assignment.
  n.id in w.src.overwriteDrops

proc dropsAfter(w: DropWalk, n: Expr, defined: var HashSet[string]): seq[Expr] =
  ## The drops that follow the assignment `n`, and its own `dropsOld` — as
  ## the emitter printed them. A declaration (`:=`, the first assignment to
  ## the name in its scope) is followed by its scope-end drops; any other
  ## plain assignment to a name freed at each overwrite drops the old value.
  ## Marks a declared name defined, as the emitter does.
  if n.target == nil: return
  if n.target.kind != exkVar:
    n.dropsOld = w.fieldDropsOld(n)
    n.dropsOldDeep = n.dropsOld and n.id in w.src.deepOverwrites
    return
  let name = n.target.name
  let taskArgs = w.bindsTaskArgs(n)
  let threaded = not taskArgs and threadedCall(n) != nil
  let fresh = name notin defined and not w.res.isOwnerField(n.target)
  # A threaded call declares only a declaration (`genThreadedAssign`).
  if fresh and (n.isDecl or not threaded):
    defined.incl name
    if taskArgs: return
    for slot in w.src.atScopeExit.getOrDefault(name):
      result.add dropOf(name, slot, n.span, w.deepAt(name, slot))
  elif not fresh and not taskArgs:
    n.dropsOld = w.dropsOldOf(n)
    n.dropsOldDeep = n.dropsOld and n.id in w.src.deepOverwrites

proc walkDrops(w: DropWalk, e: Expr, defined: var HashSet[string])

proc walkScope(w: DropWalk, e: Expr, defined: HashSet[string]) =
  ## A nested body: what it declares is gone after it (genIndented).
  var inner = defined
  w.walkDrops(e, inner)

proc walkBlock(w: DropWalk, b: Expr, defined: var HashSet[string]) =
  ## A block's statements in order, each declaration followed by its drops.
  var i = 0
  while i < b.stmts.len:
    let s = b.stmts[i]
    inc i
    if s != nil and s.kind == exkAssign:
      w.walkDrops(s.assignVal, defined)
      for drop in w.dropsAfter(s, defined):
        b.stmts.insert(drop, i)
        inc i
      continue
    w.walkDrops(s, defined)

proc walkDrops(w: DropWalk, e: Expr, defined: var HashSet[string]) =
  ## Every statement under `e`, in the order the emitter prints it.
  if e == nil: return
  case e.kind
  of exkBlock: w.walkBlock(e, defined)
  of exkIf:
    w.walkDrops(e.cond, defined)
    w.walkScope(e.thenBranch, defined)
    w.walkScope(e.elseBranch, defined)
  of exkFor:
    w.walkDrops(e.iterable, defined)
    w.walkScope(e.body, defined)
  of exkWhile:
    w.walkDrops(e.whileCond, defined)
    w.walkScope(e.whileBody, defined)
  of exkAssign:
    # Not a block's statement (a one-line branch): a declaration here would
    # need its drops after it, and there is no statement list to put them in.
    w.walkDrops(e.assignVal, defined)
    let drops = w.dropsAfter(e, defined)
    doAssert drops.len == 0,
      "ownership_nodes: " & e.target.name & " is declared outside a block " &
      "and freed at its scope's exit"
  else:
    for c in e.children: w.walkDrops(c, defined)

proc materializeParamDrops(d: Decl, src: DropSource) =
  ## The parameter slots the body owns (rule P), dropped at its every exit.
  if src.paramDrops.len == 0: return
  doAssert d.fnBody != nil and d.fnBody.kind == exkBlock,
    "ownership_nodes: " & d.name & " owns a parameter but has no block " &
    "body to put its drops in"
  var drops: seq[Expr]
  for (p, slot) in src.paramDrops:
    drops.add dropOf(p, slot, d.fnBody.span, p & "\t" & slot in src.deep)
  d.fnBody.stmts = drops & d.fnBody.stmts

type DropsOf* = proc (d: Decl): DropSource
  ## A body's drop source.

proc materializeDropsFrom*(res: Resolution, m: Module, sourceOf: DropsOf) =
  ## Every drop `sourceOf` decided becomes a node.
  var tasks: HashSet[string]
  for d in m.decls:
    if d != nil and d.kind == dkTask: tasks.incl d.name
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    let src = sourceOf(d)
    var defined: HashSet[string]
    for p in d.fnParams: defined.incl p.name
    DropWalk(res: res, src: src, tasks: tasks).walkDrops(d.fnBody, defined)
    materializeParamDrops(d, src)
    res.ssaGraphs.del((d.id, ssLowered))
