# compiler/ownership_write.nim
#
# THE RULES WRITE THEIR OWN TREE — the last step of Stage D
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §8).
#
# Stage C made today's decisions into nodes (ownership_nodes); the
# elaborator computed the rules' decisions beside them (ownership_elab) and
# rule V checks a tree of such nodes (ownership_check). Here the rules write
# the nodes themselves, on Odin, under TUCK_OWN=rules: the same `exkCopy`,
# `defer drop` and `dropsOld` the emitter already prints, decided from the
# rules instead of from today's passes. Nothing else changes, so the
# emitted program is the rules' program, and V and the tracked runs check
# it before anything switches.
#
#   P  calling convention. Every call to a fn with a moved twin calls the
#      twin, which is the body itself (twin_calls, `every`); a parameter
#      the body consumes is P's answer, for every parameter, not only the
#      first. The copying wrapper is never called.
#   S  every sink is decided: a binding, a construction's field, a list's
#      element, a `return`, a value appended, an argument to a consuming
#      parameter or to the runtime's `push`/`setAt`. A read of a place the
#      body owns moves at its final use and copies otherwise; a read of a
#      place it borrows, or of an element, always copies; a temporary moves.
#      The take, `st = {b: st} apply` (an actor's field handed over and
#      refilled by the same statement), moves.
#   D  every owned place is dropped where its scope ends unless it was moved
#      out on every path, and an overwrite drops the old value unless it was
#      moved out (the elaborator's `dropPlan`, placed by Stage C's walker).
#
#   M  a place moved on some paths only (`maybe`) is reset to empty after
#      each statement that moves it, and dropped like any other. A move in
#      a `return` binds the value first, so the reset runs before the
#      scope's drops.
#
# Two values need a NAME before a rule can apply, and get one (a binding
# inserted before the statement, as lowering_strtemps names a `str`):
#   - a temporary only borrowed (a list a `for` iterates, a call's result
#     given to a reading parameter): bound, it is an owned place, dropped
#     where its scope ends (D). Only when nothing with an effect runs before
#     it in its statement, so the order of effects is kept.
#   - a record copied where it is not bound (an argument, an element, a
#     `return`): Odin prints a record's field copies only after a binding.
#
# NOT YET, and so not written here:
#   - `str`: static or heap is rule G's answer. Its copies and drops stay
#     today's (ownership_nodes, `staticOnly`), and so does its calling
#     convention: a `str` parameter borrows.
#   - an actor's field overwritten (rule T), and a Seq's elements and a
#     sum's payloads (glue, rule G; A39).
import os, tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules, ownership_elab, ownership_nodes
from analysis_ownership import ownershipFor, Ownership
from twin_shape import ownsHeap, seqFieldNames
from twin_calls import threadedCall, markBuilt
from ssa_ir import rootOf

type Writer = object
  res: Resolution
  m: Module
  memo: ConsumeMemo
  ps: Places
  refills: string     ## the place the enclosing assignment defines (the take)
  unprinted: int      ## record copies Odin cannot print outside a binding

proc seqOwning(w: Writer, t: Type): bool =
  ## Does a value of `t` own Seq storage the rules decide (not a `str`)?
  t != nil and not isStr(t) and slotsOf(w.res, w.m, t).len > 0

proc consumed(w: var Writer, a: ArgOf): bool =
  ## Does the parameter this argument feeds consume it (rule P)?
  a.call != nil and w.res.argConsumesWhy(w.m, a, w.memo).len > 0

proc copyNode(w: Writer, v: Expr, kind: CopyKind, fields: seq[string]): Expr =
  ## `v` copied; the copy is new and typed as its value.
  result = w.res.typed(Expr(span: v.span, kind: exkCopy, copied: v,
                            copyKind: kind, copyFields: fields),
                       w.res.typeFor(v))
  fillIdsIn(result)

proc taken(w: Writer, v: Expr): bool =
  ## The take: an actor's field handed over by the assignment that refills
  ## it, never seen empty.
  w.refills.len > 0 and w.res.isOwnerField(v) and pathOf(v) == w.refills

proc atSink(w: var Writer, v: Expr, atBinding: bool): Expr =
  ## `v` put to a sink: the copy rule S makes of it, or `v` itself (a move).
  let t = w.res.typeFor(v)
  if v == nil or v.kind == exkCopy or not w.seqOwning(t) or w.taken(v) or
     not w.res.copiesRead(w.ps, v):
    return v
  if seqElem(t) != nil: return w.copyNode(v, cpSeq, @[])
  if atBinding: return w.copyNode(v, cpFields, seqFieldNames(w.res, w.m, t))
  inc w.unprinted
  v

proc walk(w: var Writer, e: Expr, use: Use, arg: ArgOf)

proc visit(w: var Writer, slot: var Expr, use: Use, arg: ArgOf,
           atBinding = false) =
  ## One operand, put to `use`: copied if it is a sink that copies, then
  ## walked for the operands inside it.
  if slot == nil: return
  if use == uSink or (use == uArg and w.consumed(arg)):
    slot = w.atSink(slot, atBinding)
  if slot.kind == exkCopy: w.walk(slot.copied, uBorrow, NoArg)
  else: w.walk(slot, use, arg)

type Operand = tuple[child: Expr, use: Use, arg: ArgOf]

proc operands(w: Writer, e: Expr, use: Use, arg: ArgOf): seq[Operand] =
  ## `e`'s operands with the use each is put to once `use` is known (rule
  ## U), and the parameter each argument feeds.
  var argNo = 0
  for (c, u) in w.res.uses(e):
    var a = NoArg
    if u in {uThrough, uProject}: a = arg
    elif u == uArg and e.kind == exkCall:
      a = argOf(e, argNo)
      inc argNo
    result.add (c, effective(use, u), a)

proc find(ops: seq[Operand], c: Expr): int =
  ## The operand that IS `c` (identity), or -1.
  for i, o in ops:
    if o.child == c: return i
  -1

proc walkAssign(w: var Writer, n: Expr) =
  ## The value is a sink (copied where it is bound); the take is noticed.
  let outer = w.refills
  w.refills = if n.target != nil: pathOf(n.target) else: ""
  w.visit(n.assignVal, uSink, NoArg, atBinding = true)
  w.refills = outer

proc walk(w: var Writer, e: Expr, use: Use, arg: ArgOf) =
  ## Every operand under `e`, each decided where it is put.
  if e == nil or w.res.isPlaceRead(e): return
  if e.kind != exkCall and w.res.hasCall(e):
    w.walk(w.res.call(e), use, arg)      # the call printed in e's place
    return
  if e.kind == exkAssign:
    w.walkAssign(e)
    return
  let ops = w.operands(e, use, arg)
  let payload = if e.kind == exkCall: payloadOf(e) else: nil
  for slot in e.childSlots:
    let k = ops.find(slot)
    if k >= 0: w.visit(slot, ops[k].use, ops[k].arg)
    elif slot != nil and slot == payload:
      for field in slot.childSlots:
        let j = ops.find(field)
        if j >= 0: w.visit(field, ops[j].use, ops[j].arg)
        else: w.walk(field, uNone, NoArg)
    else: w.walk(slot, uNone, NoArg)

proc writeCopies(w: var Writer, d: Decl) =
  ## Rule S over one body: its value is the fn's result, a sink.
  w.ps = w.res.placesOf(w.m, d, w.memo)
  w.walk(d.fnBody, uSink, NoArg)

# --- names for values a rule needs to see bound -------------------------------

var tmpCount: int
  ## Numbers the bindings this pass makes, unique in a build.

proc bindHere(res: Resolution, n: Expr): Expr =
  ## `n` becomes a read of a new local, and the binding of what `n` was is
  ## returned. The value keeps its node's id, so its type and every fact
  ## recorded against it follow it; the read is its local's only one, so it
  ## is final.
  inc tmpCount
  let name = "tuckOwnTmp" & $tmpCount
  let t = res.typeFor(n)
  let val = Expr()
  val[] = n[]
  n[] = Expr(span: val.span, kind: exkVar, name: name)[]
  res.setType(n, t)
  res.markLastUseId(n.id)
  let target = res.typed(Expr(span: val.span, kind: exkVar, name: name), t)
  result = Expr(span: val.span, kind: exkAssign, target: target,
                assignVal: val, isDecl: true)
  fillIdsIn(result)
  markBuilt(result)
  markBuilt(n)

proc isTemporary(w: Writer, n: Expr): bool =
  ## A value no place holds: a call's result, a construction, a list. An
  ## element read is its container's.
  let c = if n.kind != exkCall and w.res.hasCall(n): w.res.call(n) else: n
  c != nil and c.kind in {exkCall, exkList, exkFill} and
    not w.res.isPlaceRead(n) and not w.res.readsElement(n) and
    w.seqOwning(w.res.typeFor(n))

proc copiedRecord(w: Writer, n: Expr): bool =
  ## A record that rule S copies (it is not printable away from a binding).
  let t = w.res.typeFor(n)
  w.seqOwning(t) and seqElem(t) == nil and not w.taken(n) and
    w.res.copiesRead(w.ps, n)

type Lift = object
  lifted: seq[Expr]   ## bindings to insert before the statement, in order
  effects: bool       ## something with an effect already ran in it

proc pure(w: Writer, n: Expr): bool =
  ## A call that can run earlier without anyone seeing: a fn with a body
  ## that declares no effect (`[io]`, `[may_block]`, ... are checked) and
  ## sends nothing. Anything else, the runtime's included, has an effect.
  let c = if n.kind != exkCall and w.res.hasCall(n): w.res.call(n) else: n
  if c == nil or c.kind != exkCall: return false
  let d = w.res.calleeOf(w.m, c)
  if d == nil or d.fnBody == nil or d.fnEffects.len > 0: return false
  for x in d.fnBody.nodes:
    if x.kind == exkSend: return false
  true

proc conditional(n: Expr): bool =
  ## Evaluated on some paths only, or more than once: nothing in it moves
  ## ahead of its statement.
  n.kind in {exkIf, exkMatch, exkBlock, exkSelect, exkFor, exkWhile,
             exkDefer} or
    (n.kind == exkBinary and n.binOp in {boAnd, boOr})

proc liftSelf(w: var Writer, n: Expr, use: Use, arg: ArgOf, L: var Lift,
              before: bool) =
  ## `n` itself, its operands done: named if a rule needs it named; `before`
  ## is whether something with an effect ran ahead of it.
  let sink = use == uSink or (use == uArg and w.consumed(arg))
  if sink and w.copiedRecord(n):
    L.lifted.add w.res.bindHere(n)            # a pure read: no order to keep
  elif not sink and use notin {uThrough, uProject, uNone} and
       w.isTemporary(n) and not before:
    L.lifted.add w.res.bindHere(n)
    L.effects = before
  elif (n.kind == exkCall or w.res.hasCall(n)) and not w.pure(n):
    L.effects = true

proc lift(w: var Writer, n: Expr, use: Use, arg: ArgOf, L: var Lift,
          own = false) =
  ## Operands first, in the order they run, then `n` itself; `own`: `n` is
  ## the statement's bound value, already named.
  if n == nil: return
  if conditional(n):
    L.effects = true
    return
  let before = L.effects
  if not w.res.isPlaceRead(n):
    let c = if n.kind != exkCall and w.res.hasCall(n): w.res.call(n) else: n
    for o in w.operands(c, use, arg): w.lift(o.child, o.use, o.arg, L)
  if not own: w.liftSelf(n, use, arg, L, before)

proc liftStatement(w: var Writer, s: Expr): seq[Expr] =
  ## The bindings statement `s` needs before it.
  var L: Lift
  case s.kind
  of exkAssign:
    let outer = w.refills
    w.refills = if s.target != nil: pathOf(s.target) else: ""
    w.lift(s.assignVal, uSink, NoArg, L, own = true)
    w.refills = outer
  of exkReturn: w.lift(s.returnVal, uSink, NoArg, L)
  of exkRaise: w.lift(s.raiseVal, uSink, NoArg, L)
  of exkFor: w.lift(s.iterable, uBorrow, NoArg, L)
  of exkIf: w.lift(s.cond, uBorrow, NoArg, L)
  of exkMatch: w.lift(s.subject, uBorrow, NoArg, L)
  of exkWhile, exkBlock, exkDefer, exkSelect, exkBreak, exkContinue: discard
  else: w.lift(s, uNone, NoArg, L, own = true)
  L.lifted

proc liftAll(w: var Writer, d: Decl) =
  ## Every block's statements, each given the bindings it needs.
  w.ps = w.res.placesOf(w.m, d, w.memo)
  var blocks: seq[Expr]
  for n in d.fnBody.nodes:
    if n.kind == exkBlock: blocks.add n
  for b in blocks:
    var i = 0
    while i < b.stmts.len:
      let lifted = w.liftStatement(b.stmts[i])
      for j, l in lifted: b.stmts.insert(l, i + j)
      i += lifted.len + 1

# --- rule M: a place moved on some paths is reset where it moves ---------------

proc contains(res: Resolution, s, read: Expr): bool =
  ## Is `read` in statement `s`, or in a call printed in a node's place?
  for n in s.nodes:
    if n == read: return true
    if n.kind != exkCall and res.hasCall(n) and res.contains(res.call(n), read):
      return true
  false

proc statementOf(res: Resolution, body, read: Expr): tuple[b: Expr, i: int] =
  ## The innermost block statement holding `read`, or (nil, -1).
  result = (nil, -1)
  for b in body.nodes:
    if b.kind != exkBlock: continue
    for i, s in b.stmts:
      if res.contains(s, read): result = (b, i)

proc resetOf(w: Writer, read: Expr, place, slot: string): Expr =
  ## `place.slot = {}`: the slot is empty, and its drop frees nothing. The
  ## empty value is untyped, so Odin takes the type from the target (a
  ## generic record's field type has no name here).
  let whole = pathOf(read) == place
  let span = read.span
  var target = w.res.typed(Expr(span: span, kind: exkVar, name: place),
    if whole: w.res.typeFor(read)
    elif read.kind == exkField: w.res.typeFor(read.receiver)
    else: nil)
  if slot.len > 0:
    let t = if pathOf(read) == place & "." & slot: w.res.typeFor(read) else: nil
    target = w.res.typed(Expr(span: span, kind: exkField, receiver: target,
                              fieldName: slot), t)
  let empty = w.res.typed(Expr(span: span, kind: exkList), nil)
  result = Expr(span: span, kind: exkAssign, target: target, assignVal: empty)
  fillIdsIn(result)
  markBuilt(result)

proc resetAfter(w: var Writer, d: Decl, key: string, read: Expr): bool =
  ## A reset of the slot `key` right after the statement whose `read` moved
  ## it; false when there is no statement position to put it in.
  let (b, i) = w.res.statementOf(d.fnBody, read)
  if b == nil: return false
  let (place, slot) = (key.split('\t')[0], key.split('\t')[1])
  let s = b.stmts[i]
  case s.kind
  of exkReturn, exkRaise:
    # The value is bound first, so the reset runs before the scope's drops.
    let v = if s.kind == exkReturn: s.returnVal else: s.raiseVal
    b.stmts.insert(w.res.bindHere(v), i)
    b.stmts.insert(w.resetOf(read, place, slot), i + 1)
  of exkIf, exkWhile, exkFor, exkMatch, exkBlock, exkSelect, exkDefer:
    return false                       # moved in a condition: nowhere to go
  else: b.stmts.insert(w.resetOf(read, place, slot), i + 1)
  true

# --- rule D, as a drop source ---------------------------------------------------

proc split(k: string): tuple[place, slot: string] =
  let parts = k.split('\t')
  (parts[0], if parts.len > 1: parts[1] else: "")

proc resetMoves(w: var Writer, d: Decl, plan: DropPlan,
                keys: HashSet[string]): HashSet[string] =
  ## Rule M: every move of the slots in `keys` is followed by a reset of
  ## the slot. Returns the keys some move of which could not be reset.
  var done: HashSet[NodeId]
  for k in keys:
    for read in plan.moves.getOrDefault(k):
      if read.id in done: continue
      done.incl read.id
      if not w.resetAfter(d, k, read): result.incl k

proc maybeKeys(d: Decl, plan: DropPlan): HashSet[string] =
  ## The slots moved on some paths and still dropped: a `maybe` where the
  ## scope ends, or the old value of a `maybe` overwrite.
  for k, fate in plan.scopeEnd:
    if fate == fMaybe and k.split('\t')[0] notin plan.strs: result.incl k
  for n in d.fnBody.nodes:
    if n.kind != exkAssign or plan.overwrite.getOrDefault(n.id) != fMaybe:
      continue
    let root = rootOf(pathOf(n.target))
    for k in plan.scopeEnd.keys:
      if k.split('\t')[0] == root: result.incl k

proc scopeEndDrops(d: Decl, plan: DropPlan, unreset: HashSet[string],
                   src: var DropSource) =
  ## Every slot still owned where its scope ends (a `maybe` one once reset
  ## where it moves): a parameter's at the body's exits, a local's after its
  ## declaration.
  var params: HashSet[string]
  for p in d.fnParams: params.incl p.name
  for k, fate in plan.scopeEnd:
    let (place, slot) = split(k)
    if place in plan.strs or fate == fMoved or k in unreset: continue
    if place in params: src.paramDrops.add (place, slot)
    else: src.atScopeExit.mgetOrPut(place, @[]).add slot

proc dropsOld(n: Expr, plan: DropPlan, unreset: HashSet[string]): bool =
  ## Does this overwrite drop the old value? When it is owned, or `maybe`
  ## with every move of the place reset.
  let fate = plan.overwrite.getOrDefault(n.id, fMoved)
  if fate == fOwned: return true
  if fate != fMaybe: return false
  let root = rootOf(pathOf(n.target))
  for k in unreset:
    if k.split('\t')[0] == root: return false
  true

proc overwriteDrops(d: Decl, plan: DropPlan, unreset: HashSet[string],
                    today: Ownership, src: var DropSource) =
  ## Every overwrite whose old value is still owned; a `str` as today.
  for n in d.fnBody.nodes:
    if n.kind != exkAssign or n.target == nil or
       n.target.kind notin {exkVar, exkField}:
      continue
    let name = rootOf(pathOf(n.target))
    if n.target.kind == exkVar and name in plan.strs:
      if name in today.freeBeforeOverwrite and threadedCall(n) == nil:
        src.overwriteDrops.incl n.id
    elif dropsOld(n, plan, unreset):
      src.overwriteDrops.incl n.id

proc rulesDrops(w: var Writer, d: Decl): DropSource =
  ## Rules D and M for one body, as a drop source: every owned place still
  ## owned where its scope ends, a `maybe` one once it is reset where it
  ## moves, and every overwrite whose old value is still owned. A `str`
  ## keeps today's frees (rule G).
  result.byAssignment = true
  let plan = w.res.dropPlan(w.m, d)
  let unreset = w.resetMoves(d, plan, maybeKeys(d, plan))
  scopeEndDrops(d, plan, unreset, result)
  let today = ownershipFor(d)
  for name, slots in today.freeAtScopeExit:
    if name in plan.strs: result.atScopeExit[name] = slots
  overwriteDrops(d, plan, unreset, today, result)

proc writeRules*(res: Resolution, m: Module) =
  ## TUCK_OWN=rules, on Odin: the rules write the copies, drops and resets
  ## (step 9, in place of today's). Run after the appends are made.
  var w = Writer(res: res, m: m)
  var sources: Table[NodeId, DropSource]
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    w.liftAll(d)
    w.writeCopies(d)
    sources[d.id] = w.rulesDrops(d)
  materializeCopies(res, m, ownsStrs = true, staticOnly = true)
  materializeDropsFrom(res, m, proc (d: Decl): DropSource =
    sources.getOrDefault(d.id))
  if getEnv("TUCK_DEBUG_OWN") == "write" and w.unprinted > 0:
    echo "WRITE unprinted record copies: ", w.unprinted
