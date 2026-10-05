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
# Stage D then makes the same nodes from the rules instead of from today's
# predicates, and a differential compares the two.
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
# it replaces: the copy marks and provenance (which ask selfAppendValue
# themselves, to learn that `xs` keeps its buffer), ownership and the twin
# marks. The node keeps the assignment's id, so every fact recorded against
# the statement — its type (void), a shortcut site — stays attached.
#
# SECOND NODE: `exkCopy` — the value a binding copies (step 1.2).
#
#   cpSeq     a `Seq` bound where Odin's `[dynamic]T` / D's `T[]` would share
#             the buffer (lowering_seqcopy's `needsDup`)
#   cpFields  a record whose `Seq` fields would be shared the same way, one
#             level down (`recordDupFields`)
#   cpStatic  a `str` literal the ownership pass decided its local must own,
#             so the free at its overwrite never frees static storage
#             (`copyToOwn`, Odin only)
#
# Made exactly where the emitters printed them: on an assignment's value,
# except a task's awaited result and a call threaded through a moved twin —
# both already the binder's alone. (The copy MARKS can sit on those two too:
# lowering_seqcopy marks every non-exclusive binding, and the ownership pass
# still reads the mark there as "copied". That disagreement is real and is
# what Stage D's differential is for; here it is carried over unchanged.)
# The aliasing backends only: Nim's assignment copies by itself.
#
# THIRD NODE: `exkDrop` — release what a place owns (step 1.3, Odin only).
#
#   scope end    `defer drop(x.slot)` as the statements after the one that
#                DECLARES `x` (the ownership pass's `freeAtScopeExit`)
#   overwrite    the assignment's own `dropsOld`: drop-and-replace, because
#                the old value dies after the new one is built and before it
#                is stored, and there is no statement position between the
#                two without minting a temporary (`freeBeforeOverwrite`)
#   moved twin   `defer drop(p.slot)` at the top of a twin's body, for the
#                parameter slots it consumed (`twinFreesParam`)
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
import tables, sets, os
import ast, ast_ops, ast_query
import resolution
import ssa_ir
import lowering_seqcopy
import analysis_ownership
import twin_calls
import twin_shape

let DebugUnbacked = not defined(release) and
                    getEnv("TUCK_DEBUG_INPLACE").len > 0
  ## Read once at module init, not per assignment.

proc reportUnbacked(res: Resolution, n: Expr, why: string) =
  ## ITEM 4, MEASURED (thoughts/ssa-mirror-design.md, Stage C): a binding
  ## `markSeqCopies` marked as copied — a call is not `exclusivelyOwned` —
  ## that gets no copy here, because it is an append grown in place, a call
  ## threaded through a moved twin, or a task's awaited result. The ownership
  ## pass reads the mark as "copied, so fresh" (`afterBinding`), and at
  ## exactly these sites nothing backs the claim. Moved here from the Odin
  ## emitter, which could see only the twin case, and only on Odin.
  when not defined(release):
    if DebugUnbacked and n.assignVal != nil and
       (needsDup(res, n.assignVal) or
        recordDupFields(res, n.assignVal).len > 0):
      echo "INPLACE-BYPASS ", pathOf(n.target), " at ", n.span.line, ":",
           n.span.col, " (", why, ")"

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

proc materialize(res: Resolution, n: Expr, strGrows: bool): bool =
  ## Rewrites `n` if it is an append assigned back over its own argument.
  let pushed = selfAppendParts(res, n)
  if pushed.value != nil:
    reportUnbacked(res, n, "append")
    materializeAppend(n, pushed, element = true)
    return true
  if not strGrows: return false
  let concatenated = selfConcatParts(res, n)
  if concatenated.value == nil: return false
  reportUnbacked(res, n, "append")
  materializeAppend(n, concatenated, element = false)
  true

proc materializeAppends*(res: Resolution, m: Module, strGrows: bool) =
  ## Every append assigned back over its own argument becomes `exkAppend`.
  ## `strGrows`: the backend's `str` grows in place (Nim, D — not Odin, whose
  ## strings are a pointer and a length, so `s = s + t` stays a concat and a
  ## free of the old value).
  for d in m.allDecls:
    var changed = false
    for body in d.ownExprs:
      if body == nil: continue
      for n in body.nodes:
        if n.kind == exkAssign and materialize(res, n, strGrows):
          changed = true
    if changed and d.id.isSet:
      res.ssaGraphs.del((d.id, ssLowered))

proc copyOf(res: Resolution, v: Expr, ownedStrs: HashSet[NodeId]):
    tuple[kind: CopyKind, fields: seq[string], any: bool] =
  ## What copy the binding of `v` makes, from the marks the passes recorded.
  if needsDup(res, v): return (cpSeq, @[], true)
  let fields = recordDupFields(res, v)
  if fields.len > 0: return (cpFields, fields, true)
  if v.id.isSet and v.id in ownedStrs:
    doAssert v.kind == exkLit and v.litKind == lkStr,
      "ownership marked a non-literal to copy: " & $v.kind
    return (cpStatic, @[], true)

proc bindsTask(tasks: HashSet[string], e: Expr): bool =
  ## `let r = {args} someTask`: the value is the task's awaited result.
  let v = e.assignVal
  v != nil and v.kind == exkCall and v.callee != nil and
    v.callee.kind == exkVar and v.callee.name in tasks

proc materializeCopy(res: Resolution, n: Expr, ownedStrs: HashSet[NodeId],
                     staticOnly: bool) =
  ## Wraps the value `n` binds in the copy it makes, if any. The value keeps
  ## its node and id; the copy is new, and typed as its value. `staticOnly`:
  ## only a `str` literal made owned (the rules decide every other copy).
  let v = n.assignVal
  if v == nil: return
  let (kind, fields, any) = copyOf(res, v, ownedStrs)
  if not any or (staticOnly and kind != cpStatic): return
  n.assignVal = res.typed(Expr(span: v.span, kind: exkCopy, copied: v,
                               copyKind: kind, copyFields: fields),
                          res.typeFor(v))

proc materializeCopies*(res: Resolution, m: Module, ownsStrs: bool,
                        staticOnly = false) =
  ## Every copy a binding makes becomes `exkCopy`. On the aliasing backends
  ## only; `ownsStrs`: this backend frees `str` (Odin), so a literal its
  ## local must own is copied to the heap. `staticOnly`: only those literals
  ## (under TUCK_OWN=rules, where the rules decide the rest).
  var tasks: HashSet[string]
  for d in m.decls:
    if d != nil and d.kind == dkTask: tasks.incl d.name
  var fns: HashSet[NodeId]
  for d in m.allFns: fns.incl d.id
  for d in m.allDecls:
    let ownedStrs = if ownsStrs and d.id in fns: ownershipFor(d).copyToOwn
                    else: initHashSet[NodeId]()
    for body in d.ownExprs:
      if body == nil: continue
      for n in body.nodes:
        if n.kind != exkAssign: continue
        if bindsTask(tasks, n): reportUnbacked(res, n, "task")
        elif threadedCall(n) != nil: reportUnbacked(res, n, "threaded")
        else: materializeCopy(res, n, ownedStrs, staticOnly)

proc dropOf(name, slot: string, span: Span): Expr =
  ## `defer drop(name.slot)` — the place as a path ("" slot: the whole value).
  var place = Expr(span: span, kind: exkVar, name: name)
  if slot.len > 0:
    place = Expr(span: span, kind: exkField, receiver: place, fieldName: slot)
  let drop = Expr(span: span, kind: exkDrop, dropped: place)
  result = Expr(span: span, kind: exkDefer,
                deferBody: Expr(span: span, kind: exkBlock, stmts: @[drop]))
  fillIdsIn(result)     # every node after prepare has one (assertTreeIds)

type DropSource* = object
  ## Where one body's drops come from: today's ownership pass, or the rules
  ## (ownership_write). The placement below is the same for both.
  atScopeExit*: Table[string, seq[string]]
    ## owned place -> the slots dropped where its scope ends
  byAssignment*: bool
    ## the rules decide each overwrite by the assignment (`overwriteDrops`);
    ## today's pass decides by the name (`overwriteNames`)
  overwriteDrops*: HashSet[NodeId]
  overwriteNames*: HashSet[string]
  paramDrops*: seq[tuple[param, slot: string]]
    ## parameter slots the body owns, dropped at its every exit

proc todaysDrops(res: Resolution, m: Module, d: Decl): DropSource =
  ## Today's ownership pass, as a drop source: its scope-end frees, the names
  ## freed at each overwrite, and a moved twin's parameter.
  let own = ownershipFor(d)
  result.atScopeExit = own.freeAtScopeExit
  result.overwriteNames = own.freeBeforeOverwrite
  let p = movedFnParam(res, m, d)
  if p != "":
    for slot in own.twinFreesParam: result.paramDrops.add (p, slot)

type DropWalk = object
  res: Resolution
  src: DropSource
  tasks: HashSet[string]

proc bindsTaskArgs(w: DropWalk, n: Expr): bool =
  ## `let r = {args} someTask` — printed by its own path, which frees nothing.
  let v = n.assignVal
  v != nil and v.kind == exkCall and v.callee != nil and
    v.callee.kind == exkVar and v.callee.name in w.tasks and v.args.len > 0

proc fieldDropsOld(w: DropWalk, n: Expr): bool =
  ## An overwrite of one field (`b.items = v`): only the rules drop there.
  w.src.byAssignment and n.target.kind == exkField and
    n.id in w.src.overwriteDrops

proc dropsOldOf(w: DropWalk, n: Expr, threaded: bool): bool =
  ## Does this overwrite drop the value it replaces? The rules decide by the
  ## assignment; today's pass by the name, never across a threaded call.
  if w.src.byAssignment: n.id in w.src.overwriteDrops
  else: not threaded and n.target.name in w.src.overwriteNames

proc dropsAfter(w: DropWalk, n: Expr, defined: var HashSet[string]): seq[Expr] =
  ## The drops that follow the assignment `n`, and its own `dropsOld` — as
  ## the emitter printed them. A declaration (`:=`, the first assignment to
  ## the name in its scope) is followed by its scope-end drops; any other
  ## plain assignment to a name freed at each overwrite drops the old value.
  ## Marks a declared name defined, as the emitter does.
  if n.target == nil: return
  if n.target.kind != exkVar:
    n.dropsOld = w.fieldDropsOld(n)
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
      result.add dropOf(name, slot, n.span)
  elif not fresh and not taskArgs: n.dropsOld = w.dropsOldOf(n, threaded)

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
  ## The parameter slots the body owns, dropped at its every exit: a moved
  ## twin's consumed parameter today, a consuming parameter (P) by the rules.
  if src.paramDrops.len == 0: return
  doAssert d.fnBody != nil and d.fnBody.kind == exkBlock,
    "ownership_nodes: " & d.name & " owns a parameter but has no block " &
    "body to put its drops in"
  var drops: seq[Expr]
  for (p, slot) in src.paramDrops: drops.add dropOf(p, slot, d.fnBody.span)
  d.fnBody.stmts = drops & d.fnBody.stmts

type DropsOf* = proc (d: Decl): DropSource
  ## A body's drop source.

proc materializeDropsFrom*(res: Resolution, m: Module, sourceOf: DropsOf) =
  ## Every drop `sourceOf` decided becomes a node. Odin only.
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

proc materializeDrops*(res: Resolution, m: Module) =
  ## Every free the ownership pass decided becomes a drop. Odin only.
  materializeDropsFrom(res, m, proc (d: Decl): DropSource =
    todaysDrops(res, m, d))
