# compiler/ownership_write.nim
#
# THE RULES WRITE THEIR OWN TREE — the last step of Stage D
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §8).
#
# Stage C made today's decisions into nodes (ownership_nodes); the
# elaborator computed the rules' decisions beside them (ownership_elab) and
# rule V checks a tree of such nodes (ownership_check). Here the rules write
# the nodes themselves on the COMMON LOWERED AST, before any backend clone:
# explicit `exkCopy`, `exkMove`, `exkDrop`, `exkReset`,
# `defer drop` and `dropsOld` the emitter already prints, decided from the
# rules instead of from today's passes. Nothing else changes, so the
# emitted program is the rules' program, and V and the tracked runs check
# it before backend emission. This is now the default on all backends.
#
#   P  calling convention. Record consumption on each parameter once.
#      Emit one implementation, without legacy copying wrappers/twins.
#   S  every sink is decided: a binding, a construction's field, a list's
#      element, a `return`, a value appended, an argument to a consuming
#      parameter (a callee with no body by its signature's contract). A
#      read of a place the
#      body owns moves at its final use and copies otherwise; a read of a
#      place it borrows, or of an element, always copies; a temporary moves.
#      Singleton state reads copy; overwrites release the old owned state.
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
# Type-derived G handles nested records, arrays, strings, recursive sums
# and result payloads. Static strings are cloned at owning sinks. Tasks and
# both forms of message handlers use the same semantic body rules.
import os, tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules, ownership_elab, ownership_nodes
from analysis_ownership import ownershipFor, Ownership
from twin_shape import ownsHeap, seqFieldNames
from twin_calls import threadedCall, markBuilt
from ssa_ir import rootOf
import ownership_glue
from ssa_liveness import markLoweredLiveness

type Writer = object
  res: Resolution
  m: Module
  memo: ConsumeMemo
  ps: Places
  refills: string     ## the place the enclosing assignment defines (the take)
  unprinted: int      ## record copies Odin cannot print outside a binding

proc seqOwning(w: Writer, t: Type): bool =
  ## Does a value of `t` own Seq storage the rules decide (not a `str`)?
  t != nil and ownsStorage(w.m, t)

proc consumed(w: var Writer, a: ArgOf): bool =
  ## Does the parameter this argument feeds consume it (rule P)?
  a.call != nil and w.res.argConsumesWhy(w.m, a, w.memo).len > 0

proc copyNode(w: Writer, v: Expr, kind: CopyKind, fields: seq[string]): Expr =
  ## `v` copied; the copy is new and typed as its value.
  let original = Expr()
  original[] = v[]
  result = w.res.typed(Expr(span: v.span, kind: exkCopy, copied: original,
                            copyKind: kind, copyFields: fields),
                       w.res.typeFor(v))
  fillIdsIn(result)
  # Resolved calls can share this operand. Replace its object in place,
  # rather than leaving an unelaborated reference in Resolution.calls.
  v[] = result[]
  result = v

proc taken(w: Writer, v: Expr): bool =
  ## The take: an actor's field handed over by the assignment that refills
  ## it, never seen empty.
  w.refills.len > 0 and w.res.isOwnerField(v) and pathOf(v) == w.refills

proc moveNode(w: Writer, v: Expr): Expr =
  let original = Expr()
  original[] = v[]
  let wrapper = w.res.typed(Expr(span: v.span, kind: exkMove,
                                movedValue: original), w.res.typeFor(v))
  fillIdsIn(wrapper)
  v[] = wrapper[]
  v

proc atSink(w: var Writer, v: Expr, atBinding: bool): Expr =
  ## `v` put to a sink: the copy rule S makes of it, or `v` itself (a move).
  let t = w.res.typeFor(v)
  if v != nil and v.kind == exkLit and v.litKind == lkStr and t == nil:
    w.res.setType(v, Type(kind: tkNamed, name: "str"))
    return w.copyNode(v, cpValue, @[])
  if v == nil or v.kind in {exkCopy, exkMove} or not w.seqOwning(t): return v
  if (isStr(t) and v.kind == exkLit) or w.res.copiesRead(w.ps, v):
    return w.copyNode(v, cpValue, @[])
  if w.res.isPlaceRead(v): return w.moveNode(v)
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
  elif slot.kind == exkMove: w.walk(slot.movedValue, uBorrow, NoArg)
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
  if e.kind notin ByOwnKind and w.res.hasCall(e):
    w.walk(w.res.call(e), use, arg)      # the call printed in e's place
    return
  if e.kind == exkAssign:
    w.walkAssign(e)
    return
  if e.kind == exkBracketAssign:
    w.visit(e.brValue, uSink, NoArg)
    let typ = w.res.typeFor(e.brValue)
    if ownsStorage(w.m, typ): e.replacedType = typ
    w.walk(e.brTarget, uMutBorrow, NoArg)
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
  let site = res.shortcut(val)
  if site.len > 0:
    # Error handling belongs to the statement that now evaluates the call,
    # not to the later read/discard of the bound owning value.
    res.setShortcut(result, site)
    res.shortcuts.del val.id
  markBuilt(result)
  markBuilt(n)

proc isTemporary(w: Writer, n: Expr): bool =
  ## A value no place holds: a call's result, a construction, a list. An
  ## element read is its container's.
  let c = if n.kind notin ByOwnKind and w.res.hasCall(n): w.res.call(n) else: n
  c != nil and c.kind in {exkCall, exkList, exkFill, exkBinary, exkWrapOk, exkIfaceCall} and
    not w.res.isPlaceRead(n) and not w.res.readsElement(w.m, n) and
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
  let c = if n.kind notin ByOwnKind and w.res.hasCall(n): w.res.call(n) else: n
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
  if not sink and use notin {uThrough, uProject} and
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
  if n.kind == exkIfaceCall:
    # Arms execute inside the dispatch closure. Never lift their payload
    # reads or calls into the enclosing scope.
    w.lift(n.dispatchRecv, uBorrow, NoArg, L)
  elif not w.res.isPlaceRead(n):
    let c = if n.kind notin ByOwnKind and w.res.hasCall(n): w.res.call(n) else: n
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
  else:
    let discardedTemporary = w.isTemporary(s)
    w.lift(s, uNone, NoArg, L)
    if discardedTemporary and s.kind == exkVar:
      let value = w.res.freshCopy(s)
      s[] = Expr(kind: exkDiscard, span: s.span, discardVal: value)[]
      fillIdsIn(s)
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

proc resetOf(w: Writer, d: Decl, read: Expr, place, slot: string): Expr =
  ## `place.slot = {}`: the slot is empty, and its drop frees nothing. The
  ## empty value is untyped, so Odin takes the type from the target (a
  ## generic record's field type has no name here).
  let span = read.span
  var rootType: Type
  for p in d.fnParams:
    if p.name == place: rootType = ownershipParamType(d, p.typ)
  for n in d.fnBody.nodes:
    if n.kind == exkAssign and n.target != nil and n.target.kind == exkVar and
       n.target.name == place:
      rootType = if w.res.typeFor(n.target) != nil: w.res.typeFor(n.target)
                 else: w.res.typeFor(n.assignVal)
  var target = w.res.typed(Expr(span: span, kind: exkVar, name: place), rootType)
  var path = ""
  for field in slot.split('.'):
    if field.len == 0: continue
    path = if path.len == 0: field else: path & "." & field
    target = w.res.typed(Expr(span: span, kind: exkField, receiver: target,
                              fieldName: field), typeAtPath(w.m, rootType, path))
  result = Expr(span: span, kind: exkReset, resetPlace: target)
  fillIdsIn(result)
  markBuilt(result)

proc resetAfter(w: var Writer, d: Decl, key: string, read: Expr): bool =
  ## A reset of the slot `key` right after the statement whose `read` moved
  ## it; false when there is no statement position to put it in.
  let (b, i) = w.res.statementOf(d.fnBody, read)
  if b == nil: return false
  let (place, slot) = (key.split('\t')[0], key.split('\t')[1])
  let s = b.stmts[i]
  let reset = w.resetOf(d, read, place, slot)
  case s.kind
  of exkReturn, exkRaise:
    # The value is bound first, so the reset runs before the scope's drops.
    let v = if s.kind == exkReturn: s.returnVal else: s.raiseVal
    b.stmts.insert(w.res.bindHere(v), i)
    b.stmts.insert(reset, i + 1)
  of exkIf, exkWhile, exkFor, exkMatch, exkBlock, exkSelect, exkDefer:
    return false                       # moved in a condition: nowhere to go
  else: b.stmts.insert(reset, i + 1)
  true

# --- rule D, as a drop source ---------------------------------------------------

proc split(k: string): tuple[place, slot: string] =
  let parts = k.split('\t')
  (parts[0], if parts.len > 1: parts[1] else: "")

proc resetMoves(w: var Writer, d: Decl, plan: DropPlan,
                keys: HashSet[string]): HashSet[string] =
  ## Rule M: every move of the slots in `keys` is followed by a reset of
  ## the slot. Returns the keys some move of which could not be reset.
  var done: HashSet[(NodeId, string)]
  for k in keys:
    for read in plan.moves.getOrDefault(k):
      if (read.id, k) in done: continue
      done.incl (read.id, k)
      if not w.resetAfter(d, k, read): result.incl k

proc maybeKeys(d: Decl, plan: DropPlan): HashSet[string] =
  ## The slots moved on some paths and still dropped: a `maybe` where the
  ## scope ends, or the old value of a `maybe` overwrite.
  for k, fate in plan.scopeEnd:
    if fate == fMaybe: result.incl k
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
    if fate == fMoved or k in unreset: continue
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
    if dropsOld(n, plan, unreset):
      src.overwriteDrops.incl n.id

proc rulesDrops(w: var Writer, d: Decl): DropSource =
  ## Rules D and M for one body, as a drop source: every owned place still
  ## owned where its scope ends, a `maybe` one once it is reset where it
  ## moves, and every overwrite whose old value is still owned. Rule G
  ## supplies the same storage classification for strings and containers.
  result.byAssignment = true
  let plan = w.res.dropPlan(w.m, d)
  let unreset = w.resetMoves(d, plan, maybeKeys(d, plan))
  scopeEndDrops(d, plan, unreset, result)
  overwriteDrops(d, plan, unreset, Ownership(), result)

proc publishConventions(m: Module, fns: seq[Decl]) =
  for source in m.decls:
    if source == nil: continue
    if source.kind == dkTask:
      for fn in fns:
        if fn.id == source.id:
          source.taskParams = fn.fnParams
          source.taskOwnershipElaborated = true
    elif source.kind == dkActor:
      for h in source.handlers:
        if h.kind != dkSelect: continue
        for arm in h.selectArms.mitems:
          for fn in fns:
            if arm.body != nil and fn.id == arm.body.id: arm.binding = fn.fnParams

proc inferConventions(res: Resolution, m: Module, fns: seq[Decl]) =
  for d in fns:
    if d.fnBody != nil: d.ownershipElaborated = true
  publishConventions(m, fns)
  var changed = true
  while changed:
    changed = false
    for d in fns:
      if d.fnBody == nil: continue
      for p in d.fnParams.mitems:
        if p.consumes or not ownsStorage(m, ownershipParamType(d, p.typ)) or
           p.name == "self": continue
        var memo: ConsumeMemo
        if d.isOnHandler or res.consumesWhy(m, d, p.name, memo).len > 0:
          p.consumes = true
          changed = true
    publishConventions(m, fns)

proc writeRules*(res: Resolution, m: Module) =
  ## Common ownership writes copies, moves, drops and resets before cloning.
  ## Run after representation lowering and common appends.
  var w = Writer(res: res, m: m)
  # Single-line exit arms need a statement scope for the return temporary
  # and the reset that must execute before enclosing deferred drops.
  for body in m.bodies:
    for n in body.nodes:
      if n.kind notin {exkIf, exkMatch, exkFor, exkWhile}: continue
      for slot in n.childSlots:
        if slot != nil and slot.kind in {exkReturn, exkRaise}:
          slot = res.typed(Expr(kind: exkBlock, span: slot.span, stmts: @[slot]),
                            res.typeFor(slot))
          fillIdsIn(slot)
  for body in m.bodies:
    for n in body.nodes:
      res.lastUses.excl n.id
      if res.hasCall(n):
        for c in res.call(n).nodes: res.lastUses.excl c.id
  markLoweredLiveness(res, m)
  var fns: seq[Decl]
  for d in m.ownershipFns: fns.add d
  inferConventions(res, m, fns)
  for actor in m.decls(dkActor):
    for field in actor.actorFields.mitems:
      w.visit(field.default, uSink, NoArg)
  var sources: Table[NodeId, DropSource]
  for d in fns:
    if d == nil or d.fnBody == nil: continue
    w.liftAll(d)
    w.writeCopies(d)
    sources[d.id] = w.rulesDrops(d)
  materializeDropsFrom(res, m, proc (d: Decl): DropSource =
    sources.getOrDefault(d.id))
  if getEnv("TUCK_DEBUG_OWN") == "write" and w.unprinted > 0:
    echo "WRITE unprinted record copies: ", w.unprinted
