# compiler/ownership_write.nim
#
# THE RULES WRITE THE TREE — the ownership of a program, written into the
# one tree every backend prints (thoughts/shared/plans/2026-10-05-
# ownership-rules-proposal.md, §8). The elaborator (ownership_elab) answers
# the rules; this writes the answers as nodes; rule V (ownership_check)
# checks them. No backend is named here: each emitter decides how a node
# prints (backend_prepare, "ONE TREE, THREE PRINTERS").
#
#   P  calling convention. Every call to a fn with a moved twin calls the
#      twin, which is the body itself (twin_calls); the parameters the body
#      consumes are P's answer (`Decl.ownedParams`), which the copying
#      wrapper copies and Nim's `sink` reads.
#   S  every sink is decided: a binding, a construction's field, a list's
#      element, a `return`, a value appended, an argument to a consuming
#      parameter (a callee with no body by its declaration's contract). A
#      read of a place the body owns moves at its final use and copies
#      otherwise (`exkCopy`); a read of a place it borrows, or of an element,
#      always copies; a temporary moves. The take, `st = {b: st} apply` (an
#      actor's field handed over and refilled by the same statement), moves.
#   D  every owned place is dropped where its scope ends unless it was moved
#      out on every path (`exkDrop` in a `deferReleases` defer), and an
#      overwrite drops the old value unless it was moved out (`dropsOld`).
#   M  a place moved on some paths only (`maybe`) is reset after each
#      statement that moves it (`exkReset`), and dropped like any other. A
#      move in a `return` binds the value first, so the reset runs before
#      the scope's drops.
#   G  what a copy or a drop of a type is (`copyKind`, `dropDeep`).
#
# A temporary only borrowed (a list a `for` iterates, a call's result given
# to a reading parameter, a `str` concatenation's operand) gets a NAME first:
# a binding inserted before its statement, an owned place dropped where its
# scope ends (D). Only when nothing with an effect runs before it in its
# statement, so the order of effects is kept. A branch or arm that is one
# statement gets a block of its own only when a binding or a reset lands in
# it.
#
# NOT YET: an actor's field overwritten (rule T).
import tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules, ownership_elab, ownership_nodes
from twin_calls import markBuilt
from ssa_ir import rootOf

type Writer = object
  res: Resolution
  m: Module
  memo: ConsumeMemo
  ps: Places
  refills: string     ## the place the enclosing assignment defines (the take)

proc owns(w: Writer, t: Type): bool =
  ## Does a value of `t` own storage (rule G)?
  w.res.owning(w.m, t)

proc consumed(w: var Writer, a: ArgOf): bool =
  ## Does the parameter this argument feeds consume it (rule P)?
  a.call != nil and w.res.argConsumesWhy(w.m, a, w.memo).len > 0

proc copyNode(w: Writer, v: Expr, kind: CopyKind): Expr =
  ## `v` copied; the copy is new and typed as its value.
  result = w.res.typed(Expr(span: v.span, kind: exkCopy, copied: v,
                            copyKind: kind),
                       w.res.typeFor(v))
  fillIdsIn(result)

proc taken(w: Writer, v: Expr): bool =
  ## The take: an actor's field handed over by the assignment that refills
  ## it, never seen empty.
  w.refills.len > 0 and w.res.isOwnerField(v) and pathOf(v) == w.refills

proc isConstruction(w: Writer, v: Expr): bool =
  ## `State.Ready`: a path that starts at a TYPE'S name builds a value of a
  ## sum, it does not name a place.
  w.m.findDecl(dkType, pathOf(v).split('.')[0]) != nil

proc isStatic(v: Expr): bool =
  ## A `str` literal: static storage, which no owner may free.
  v.kind == exkLit and v.litKind == lkStr

proc atSink(w: var Writer, v: Expr): Expr =
  ## `v` put to a sink: the copy rule S makes of it, or `v` itself (a move).
  ## What the copy is, is rule G's.
  let t = w.res.typeFor(v)
  if v == nil or v.kind == exkCopy or not w.owns(t): return v
  if w.taken(v) or not isStatic(v) and not w.res.copiesRead(w.ps, v):
    if w.res.isPlaceRead(v) and not w.isConstruction(v):
      v.movedOut = true   # a place handed over whole
    return v
  w.copyNode(v, w.res.copyKindOf(w.m, t))

proc walk(w: var Writer, e: Expr, use: Use, arg: ArgOf)

proc visit(w: var Writer, slot: var Expr, use: Use, arg: ArgOf) =
  ## One operand, put to `use`: copied if it is a sink that copies, then
  ## walked for the operands inside it.
  if slot == nil: return
  if use == uSink or (use == uArg and w.consumed(arg)):
    slot = w.atSink(slot)
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

proc visitOne(w: var Writer, slot: var Expr, ops: seq[Operand]) =
  ## One child: visited as the operand it is, or walked as one put to no use.
  let k = ops.find(slot)
  if k >= 0: w.visit(slot, ops[k].use, ops[k].arg)
  else: w.walk(slot, uNone, NoArg)

proc walkAssign(w: var Writer, n: Expr) =
  ## The value is a sink (copied where it is bound); the take is noticed.
  let outer = w.refills
  w.refills = if n.target != nil: pathOf(n.target) else: ""
  w.visit(n.assignVal, uSink, NoArg)
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
  if e.kind == exkField and e.dotArg == nil:
    # A projection: what it reads is copied (by its parent, at its sink),
    # never the whole it reads it from (`items[i].next`).
    w.walk(e.receiver, use, arg)
    return
  let ops = w.operands(e, use, arg)
  let payload = if e.kind == exkCall: payloadOf(e) else: nil
  for slot in e.childSlots:
    if slot != nil and slot == payload and ops.find(slot) < 0:
      for field in slot.childSlots: w.visitOne(field, ops)  # the operands
    else: w.visitOne(slot, ops)

proc writeCopies(w: var Writer, d: Decl) =
  ## Rule S over one body: its value is the fn's result, a sink. And a `str`
  ## grown in a place the body owns frees its old bytes where a backend
  ## frees (an actor's field is not the body's, and may hold a literal).
  w.ps = w.res.placesOf(w.m, d, w.memo)
  w.walk(d.fnBody, uSink, NoArg)
  for n in d.fnBody.nodes:
    if n.kind == exkAppend and not n.appendsElement:
      n.appendFreesOld = not w.res.isOwnerField(n.appendTarget) and
        w.ps.owns(rootOf(pathOf(n.appendTarget)))

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
  ## A value no place holds: a call's result, a construction, a list, an
  ## operator that builds one (`a + b` on `str`). An element read is its
  ## container's.
  let c = if n.kind notin ByOwnKind and w.res.hasCall(n): w.res.call(n) else: n
  c != nil and (c.kind in {exkCall, exkList, exkFill, exkIfaceCall} or
                c.kind == exkBinary and c.binOp notin {boRangeIncl, boRangeExcl}) and
    not w.res.isPlaceRead(n) and not w.res.readsElement(w.m, n) and
    w.owns(w.res.typeFor(n))

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
  if not sink and use notin {uThrough, uProject, uNone} and
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
    # One arm runs, chosen by the receiver: nothing inside is named ahead
    # of it, and the call is a temporary as a whole.
    if not own: w.liftSelf(n, use, arg, L, before)
    L.effects = true
    return
  if not w.res.isPlaceRead(n):
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
  else: w.lift(s, uNone, NoArg, L, own = true)
  L.lifted

const ArmStatements = {exkReturn, exkRaise, exkAssign, exkBreak, exkContinue}
  ## What a branch or arm may be without a block: one statement.

proc asBlock(e: Expr): Expr =
  ## A branch or arm that is one statement, given a block of its own, so a
  ## rule can put a statement before or after it.
  if e == nil or e.kind notin ArmStatements:
    return e
  result = Expr(span: e.span, kind: exkBlock, stmts: @[e])
  fillIdsIn(result)
  markBuilt(result)

iterator armSlots(body: Expr): var Expr =
  ## Every branch and arm under `body`: a place a single statement can stand
  ## without a block of its own.
  var parents: seq[Expr]
  for n in body.nodes:
    if n.kind in {exkIf, exkMatch, exkFor, exkWhile}: parents.add n
  for n in parents:
    case n.kind
    of exkIf:
      yield n.thenBranch
      yield n.elseBranch
    of exkMatch:
      for arm in n.arms.mitems: yield arm.body
    of exkFor: yield n.body
    of exkWhile: yield n.whileBody
    else: discard

proc liftAll(w: var Writer, d: Decl) =
  ## Every block's statements, each given the bindings it needs; a branch or
  ## arm that is one statement gets a block only when it needs one.
  w.ps = w.res.placesOf(w.m, d, w.memo)
  for slot in d.fnBody.armSlots:
    if slot == nil or slot.kind notin ArmStatements: continue
    let lifted = w.liftStatement(slot)
    if lifted.len > 0:
      slot = asBlock(slot)
      slot.stmts = lifted & slot.stmts
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
  ## `reset(place.slot)`: the slot is empty, and its drop frees nothing.
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
  result = Expr(span: span, kind: exkReset, resetPlace: target)
  fillIdsIn(result)
  markBuilt(result)

proc resetPart(w: Writer, read: Expr): Expr =
  ## `reset(r.value)`: the part a read moved out of a place is empty.
  result = Expr(span: read.span, kind: exkReset,
                resetPlace: w.res.freshCopy(read))
  result.resetPlace.movedOut = false    # it names the place; it does not move it
  fillIdsIn(result)
  markBuilt(result)

proc resetAfter(w: var Writer, d: Decl, read, reset: Expr): bool =
  ## `reset` right after the statement whose `read` moved what it empties;
  ## false when there is no statement position to put it in. A branch or arm
  ## that is that one statement gets a block of its own first.
  for slot in d.fnBody.armSlots:
    if slot != nil and slot.kind != exkBlock and w.res.contains(slot, read):
      slot = asBlock(slot)
  let (b, i) = w.res.statementOf(d.fnBody, read)
  if b == nil: return false
  let s = b.stmts[i]
  case s.kind
  of exkReturn, exkRaise:
    # The value is bound first, so the reset runs before the scope's drops.
    let v = if s.kind == exkReturn: s.returnVal else: s.raiseVal
    b.stmts.insert(w.res.bindHere(v), i)
    v.movedOut = true                  # the new local's one read hands it on
    b.stmts.insert(reset, i + 1)
  of exkIf, exkWhile, exkFor, exkMatch, exkBlock, exkSelect, exkDefer:
    return false                       # moved in a condition: nowhere to go
  else: b.stmts.insert(reset, i + 1)
  true

proc copyInstead(w: Writer, read: Expr) =
  ## A move that cannot be followed by its reset becomes a copy, so the
  ## place keeps what it owns and drops it (rule S's other answer). In
  ## place: the read keeps its id, and a copy of it takes its position.
  let inner = Expr()
  inner[] = read[]
  read[] = w.copyNode(inner, w.res.copyKindOf(w.m, w.res.typeFor(inner)))[]

# --- rule D, as a drop source ---------------------------------------------------

proc split(k: string): tuple[place, slot: string] =
  let parts = k.split('\t')
  (parts[0], if parts.len > 1: parts[1] else: "")

proc refilledByStatement(w: Writer, d: Decl, read: Expr): bool =
  ## `x = f(x)`: the statement that moves `x` out also stores a new value back
  ## into it, so resetting afterwards would wipe the result (#139).
  let (b, i) = w.res.statementOf(d.fnBody, read)
  b != nil and b.stmts[i].kind == exkAssign and
    pathOf(b.stmts[i].target) == pathOf(read)

proc resetMoves(w: var Writer, d: Decl, plan: DropPlan,
                keys: HashSet[string]): HashSet[string] =
  ## Rule M: every move of the slots in `keys` is followed by a reset of
  ## the slot. Returns the keys some move of which could not be reset.
  ## A move with no statement position after it to reset in is a copy
  ## instead: the place keeps what it owns, and is dropped as planned.
  ## A read of the whole place resets the whole place, once.
  var done: HashSet[string]
  for k in keys:
    let (place, slot) = (k.split('\t')[0], k.split('\t')[1])
    for read in plan.moves.getOrDefault(k):
      let s = if pathOf(read) == place: "" else: slot
      let key = $read.id.uint32 & "\t" & s
      if key in done: continue
      done.incl key
      if w.refilledByStatement(d, read): continue
      if not w.resetAfter(d, read, w.resetOf(read, place, s)):
        w.copyInstead(read)

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

proc overwriteDrops(w: Writer, d: Decl, plan: DropPlan,
                    unreset: HashSet[string], src: var DropSource) =
  ## Every overwrite whose old value is still owned, and which of them walk
  ## it (rule G).
  for n in d.fnBody.nodes:
    if n.kind != exkAssign or n.target == nil or
       n.target.kind notin {exkVar, exkField} or not dropsOld(n, plan, unreset):
      continue
    src.overwriteDrops.incl n.id
    if w.res.dropsDeep(w.m, w.res.typeFor(n.target)):
      src.deepOverwrites.incl n.id

proc rulesDrops(w: var Writer, d: Decl): DropSource =
  ## Rules D and M for one body, as a drop source: every owned place still
  ## owned where its scope ends, a `maybe` one once it is reset where it
  ## moves, and every overwrite whose old value is still owned. What each
  ## drop is, is rule G's.
  let plan = w.res.dropPlan(w.m, d)
  let unreset = w.resetMoves(d, plan, maybeKeys(d, plan))
  for read in plan.partMoves:
    if not w.resetAfter(d, read, w.resetPart(read)): w.copyInstead(read)
  scopeEndDrops(d, plan, unreset, result)
  for k, t in plan.slotTypes:
    if w.res.dropsDeep(w.m, t): result.deep.incl k
  w.overwriteDrops(d, plan, unreset, result)

proc writeRules*(res: Resolution, m: Module) =
  ## Step 7: the rules write the bindings, copies, drops and resets into the
  ## tree every backend prints. Run after the appends are made.
  var w = Writer(res: res, m: m)
  var sources: Table[NodeId, DropSource]
  for d in m.allFnsAndTasks:
    if d == nil or d.fnBody == nil: continue
    d.ownedParams = @[]
    for p in d.fnParams:
      if res.owning(m, p.typ) and res.consumes(m, d, p.name, w.memo):
        d.ownedParams.add p.name
    w.liftAll(d)
    w.writeCopies(d)
    sources[d.id] = w.rulesDrops(d)
  materializeDropsFrom(res, m, proc (d: Decl): DropSource =
    sources.getOrDefault(d.id))
