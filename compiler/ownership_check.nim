# compiler/ownership_check.nim
#
# RULE V — CHECKED, NOT TRUSTED (thoughts/shared/plans/2026-10-05-ownership-
# rules-proposal.md, §2). After the ownership decisions are written into the
# tree, a checker walks it and confirms, for every owned place on every path:
#
#   - it is moved or dropped, exactly once: no leak, no double drop;
#   - nothing reads it after it is moved or dropped;
#   - nothing the body only borrows is dropped, or handed uncopied to a new
#     owner.
#
# It reads the TREE, the Stage C nodes an emitter prints (`exkCopy`, a
# `defer` of an `exkDrop`, an assignment's `dropsOld`, the in-place
# `exkAppend`), and not the plan that wrote them. So it checks whichever
# pass decided: today's passes now, the elaborator after the switch. A move
# is what the tree does, not what the SSA mirror proved: a sink read (rule
# U) with no copy around it hands the value over, final or not.
#
# THE CONVENTION. Which parameters a body owns, and which arguments a call
# hands over, depend on how calls are encoded. Today's aliasing backends use
# twins. A fn with a moved twin prints its body as `f_moved`, which owns its
# first parameter. A call hands its first argument over when `twin_calls`
# marked it for the twin, or when its assignment threads a container through
# it (`x = f(x, ...)`, printed `x = f_moved(x, ...)`). Every other parameter
# borrows. A callee with no Tuck body keeps the contract its signature
# states (`ownership_elab`, "What a body-less callee does"). Under rule P
# (TUCK_OWN=rules) the convention is P's answer: that is what `consumed`
# and the owned parameters read.
#
# THE STATE of an owned slot (what Odin frees: a Seq or a str itself, or a
# record's Seq fields) is the SET of what it may hold on the paths reaching
# here: live, moved out, dropped. "On some paths" falls out of the join.
# - Arms meet by union.
# - A loop is walked until its head stops growing.
# - `break` and `continue` carry their states to where they go.
# - Every exit runs the defers of the scopes it leaves, as Odin does.
# - Within one expression every operand is read before anything is handed
#   over, so `{xs: xs, n: xs.len} f` moves nothing early.
#
# TUCK_DEBUG_OWN=verify prints one line per finding, nothing for a clean
# body:
#
#   VERIFY <fn> <finding> <place> <line:col>
#
# with `(some paths)` after the finding when no path reaching it was certain.
# A finding about a drop or a leak is placed where the place was declared.
#
# Rule G supplies owning slots, including strings and nested record paths.
# Native allocator tests independently check recursive element/payload
# traversal; this checker validates transfers and lifetimes at those slots.
import os, tables, sets, strutils, sequtils
import ast, ast_ops, ast_query
import resolution
import ownership_rules, ownership_elab
import ownership_glue
from ssa_ir import rootOf
from twin_shape import ownsHeap, movedFnParam
from twin_calls import callsTwin, threadedCall

type
  Can = enum cLive, cMoved, cDropped
  Cans = set[Can]
  State = Table[string, Cans]
    ## slot key -> what the slot may hold, over every path reaching here
  Scope = object
    places: seq[string]                 ## the owned places declared here
    drops: seq[string]                  ## slots its defers drop, in order
  Loop = object
    depth: int                          ## scopes.len where the body began
    brk, cont: State                    ## joined at each break / continue
    anyBrk, anyCont: bool
  Check = object
    res: Resolution
    m: Module
    fn: string
    slots: Table[string, seq[string]]   ## owned place -> its slots
    declAt: Table[string, Span]         ## owned place -> where it began
    strs: HashSet[string]               ## the owned places that are a str
    borrowed: HashSet[string]           ## the parameters the body borrows
    rules: bool                         ## rule P's convention (TUCK_OWN=rules)
    memo: ConsumeMemo
    threaded: Expr                      ## the call the assignment being
                                        ## walked threads through a twin
    refills: string                     ## the place that assignment defines
    scopes: seq[Scope]
    loops: seq[Loop]
    st: State
    dead: bool                          ## this path has left its block
    found: OrderedTable[string, bool]   ## finding -> certain on some path
    clean: HashSet[string]              ## leak findings some exit passed

proc shown(k: string): string =
  ## A slot key as a path: `b.items`, or `xs` for the value itself.
  let parts = k.split('\t')
  if parts.len < 2 or parts[1].len == 0: parts[0]
  else: parts[0] & "." & parts[1]

proc keyOf(c: Check, what, place: string, at: Span): string =
  c.fn & " " & what & "\t" & place & " " & $at.line & ":" & $at.col

proc report(c: var Check, what: string, cans: Cans, place: string, at: Span) =
  ## One finding; `cans` is what the place may hold where it was found.
  let key = c.keyOf(what, place, at)
  c.found[key] = c.found.getOrDefault(key, false) or cans.card == 1

proc joinInto(dst: var State, src: State) =
  ## Paths meet: a slot may hold what it holds on either.
  for k, v in src: dst[k] = dst.getOrDefault(k, {}) + v

proc keysOf(c: Check, path: string): seq[string] =
  ## The owned slots a read of `path` reaches: all of a place's, or the one
  ## field's.
  let root = rootOf(path)
  if root notin c.slots: return
  if path == root:
    for s in c.slots[root]: result.add slotKey(root, s)
  else:
    let path = path[root.len + 1 .. ^1]
    for s in c.slots[root]:
      if s == path or s.startsWith(path & "."): result.add slotKey(root, s)

proc spanOf(c: Check, k: string): Span =
  ## Where the place a slot belongs to was declared.
  c.declAt.getOrDefault(k.split('\t')[0])

# --- the convention -----------------------------------------------------------

proc consumed(c: var Check, a: ArgOf): bool =
  ## Does the call take this argument over? Under rule P (TUCK_OWN=rules),
  ## P's answer. Today: a callee with no Tuck body by the contract its
  ## signature states (ownership_elab), else the moved twin's first
  ## parameter when the call was marked for the twin.
  if a.call == nil: return false
  if c.rules: return c.res.argConsumesWhy(c.m, a, c.memo).len > 0
  let t = c.res.argTarget(c.m, a)
  if t.bodyless: return c.res.bodylessKeeps(c.m, a.call, a.index)
  t.param == movedFnParam(c.res, c.m, t.callee) and
    (a.call == c.threaded or callsTwin(a.call))

proc sinks(c: var Check, pu: PlaceUse): bool =
  ## Is this read put where it is handed to a new owner? (Under rule P a
  ## `str` argument still borrows: its convention waits on rule G.)
  let t = c.res.typeFor(pu.read)
  ownsHeap(c.m, t) and
    (pu.use == uSink or
     (pu.use == uArg and c.consumed(pu.arg)))

proc idOf(e: Expr): string = $e.id.uint32

proc namedArgs(res: Resolution, call: Expr): seq[(string, Expr)] =
  ## A call's arguments with the parameter, or the field, each one feeds.
  if not call.argsExploded and call.args.len == 1 and call.args[0] != nil and
     call.args[0].kind == exkStruct:
    for f in call.args[0].fields: result.add (f.name, f.value)
  else:
    let ps = res.callParamsFor(call)
    for i, a in call.args:
      let name = if i < ps.len: ps[i] else: ""
      result.add (name, a)

proc fieldCopies(c: Check, e: Expr): HashSet[string] =
  ## The reads under `e` that a copy of a record's Seq fields (`cpFields`)
  ## copies: `<read id>` for the value a construction's field is given,
  ## `<read id>\t<field>` for one field of a record read whole. The copy is
  ## made after the binding, so the value is never handed over. (What
  ## `cpSeq` and `cpStatic` copy is a borrow already, by rule U.)
  for n in e.nodes:
    if n.kind != exkCopy or n.copyKind != cpFields: continue
    let v = n.copied
    if v.kind in {exkVar, exkField}:
      for f in n.copyFields: result.incl idOf(v) & "\t" & f
    elif v.kind == exkCall:
      for (name, a) in c.res.namedArgs(v):
        if a != nil and name in n.copyFields: result.incl idOf(a)

proc sunkSlots(c: Check, pu: PlaceUse, copies: HashSet[string]): seq[string] =
  ## The slots of the value this read hands over, less what is copied: ""
  ## for the value itself, else a record's Seq fields.
  let id = idOf(pu.read)
  if id in copies: return
  for s in slotsOf(c.res, c.m, c.res.typeFor(pu.read)):
    if id & "\t" & s notin copies: result.add s

# --- events -------------------------------------------------------------------

proc isStrSlot(c: Check, k: string): bool =
  not c.rules and k.split('\t')[0] in c.strs

proc read(c: var Check, k: string, at: Span) =
  ## A read: what it reads must not have been moved out or dropped.
  let cans = c.st.getOrDefault(k, {cLive})
  if c.isStrSlot(k) and cDropped notin cans: return  # an alias, harmless
  if cMoved in cans: c.report("use-after-move", cans, shown(k), at)
  if cDropped in cans: c.report("use-after-drop", cans, shown(k), at)

proc dropSlot(c: var Check, k: string) =
  ## A drop runs: what it frees must be live on every path.
  let cans = c.st.getOrDefault(k, {cLive})
  if cMoved in cans: c.report("drop-after-move", cans, shown(k), c.spanOf(k))
  if cDropped in cans: c.report("double-drop", cans, shown(k), c.spanOf(k))
  c.st[k] = {cDropped}

proc isTemporary(c: Check, e: Expr): bool =
  ## A value no place holds: a call's result, a construction, a list. An
  ## element read is its container's, not a new value; a `str` waits on G.
  e != nil and e.kind in {exkCall, exkList, exkFill} and
    not c.res.isPlaceRead(e) and not c.res.readsElement(c.m, e) and
    (c.rules or not isStr(c.res.typeFor(e))) and
    slotsOf(c.res, c.m, c.res.typeFor(e)).len > 0   # Seq slots; str is G's

proc fieldCopyLeaks(c: var Check, e: Expr) =
  ## A copy of a record's Seq fields (`cpFields`) replaces each listed field
  ## with its copy, in place, after the binding, and what the field held
  ## before is never dropped. That leaks it when it was fresh: the fields of
  ## a call's result, or a temporary a construction's field was given.
  let v = e.copied
  if v == nil or v.kind != exkCall or c.res.readsElement(c.m, v): return
  if not c.res.constructs(v):
    c.report("temp-leak", {cLive}, "fields", v.span)
    return
  for (name, a) in c.res.namedArgs(v):
    if name in e.copyFields and c.isTemporary(a):
      c.report("temp-leak", {cLive}, ($a.kind)[3 .. ^1].toLowerAscii, a.span)

proc temporaries(c: var Check, e: Expr, use: Use, arg: ArgOf) =
  ## Rule D for a value no place holds: unless something takes it (a sink,
  ## a consuming parameter), it is dropped where its statement ends, and
  ## the tree has no node that drops it. `use` is what `e` is put to, and
  ## `arg` the parameter it feeds when that is an argument.
  if e == nil: return
  let taken = use in {uSink, uThrough, uProject, uWrite, uDrop} or
              (use == uArg and c.consumed(arg))
  if not taken and c.isTemporary(e):
    c.report("temp-leak", {cLive}, ($e.kind)[3 .. ^1].toLowerAscii, e.span)
  if e.kind == exkCopy and e.copyKind == cpFields: c.fieldCopyLeaks(e)
  var argNo = 0
  for (ch, u) in c.res.uses(e):
    var a = NoArg
    if u in {uThrough, uProject}: a = arg      # e.g. a nullary call named bare
    elif u == uArg and e.kind == exkCall:
      a = argOf(e, argNo)
      inc argNo
    c.temporaries(ch, effective(use, u), a)

proc borrowedSink(c: Check, pu: PlaceUse): bool =
  ## Is this hand-over of a place the body only borrows (a parameter, an
  ## actor's field)? The take, `st = {b: st} apply`, is not: an actor's
  ## field handed over and refilled by the same statement (rule M) is never
  ## seen empty.
  (isSingletonRead(pu.read) or pu.path != c.refills) and
    (rootOf(pu.path) in c.borrowed or c.res.isOwnerField(pu.read) or
     isSingletonRead(pu.read))

proc take(c: var Check, pu: PlaceUse, sunk: seq[string],
          moved: var HashSet[string]) =
  ## The value a sink read hands over leaves its place: the slots in `sunk`
  ## (a whole place's) or the one field read.
  let whole = pu.path == rootOf(pu.path)
  let str = isStr(c.res.typeFor(pu.read))
  if (c.rules or not str) and c.borrowedSink(pu):
    c.report("borrowed-sunk", {cLive}, pu.path, pu.read.span)
  for k in c.keysOf(pu.path):
    if whole and k.split('\t')[1] notin sunk: continue
    if k in moved and not str:
      c.report("moved-twice", {cMoved}, shown(k), pu.read.span)
    moved.incl k
    c.st[k] = {cMoved}

proc step(c: var Check, e: Expr, use: Use) =
  ## One expression evaluated and put to `use`. Every read sees the state
  ## before it, then each uncopied sink takes its value.
  if e == nil: return
  c.temporaries(e, use, (nil, -1, ""))
  let pus = c.res.placeUsesUnder(e, use)
  for pu in pus:
    if pu.use in {uWrite, uDrop, uNone}: continue
    if not ownsHeap(c.m, c.res.typeFor(pu.read)): continue
    for k in c.keysOf(pu.path): c.read(k, pu.read.span)
  let copies = c.fieldCopies(e)
  var moved: HashSet[string]
  for pu in pus:
    if not c.sinks(pu): continue
    let sunk = c.sunkSlots(pu, copies)
    if sunk.len > 0: c.take(pu, sunk, moved)

proc declare(c: var Check, place: string, t: Type, at: Span) =
  ## An owned place begins here, live.
  let ss = slotsOf(c.res, c.m, t)
  if ss.len == 0: return
  c.slots[place] = ss
  c.declAt[place] = at
  c.scopes[^1].places.add place
  if isStr(t): c.strs.incl place
  for s in ss: c.st[slotKey(place, s)] = {cLive}

proc deferDrops(c: var Check, e: Expr) =
  ## `defer drop(p)`: registered here, run where this scope ends.
  for n in e.deferBody.nodes:
    if n.kind != exkDrop: continue
    let path = pathOf(n.dropped)
    let keys = c.keysOf(path)
    if rootOf(path) in c.borrowed:
      c.report("borrowed-dropped", {cLive}, path, n.span)
    elif keys.len == 0:
      c.report("untracked-drop", {cLive}, path, n.span)
    c.scopes[^1].drops.add keys

proc close(c: var Check, i: int) =
  ## Scope `i` ends on this path: its defers drop, last first, and what it
  ## declared must be gone, dropped or moved out.
  let sc = c.scopes[i]
  for j in countdown(sc.drops.high, 0): c.dropSlot(sc.drops[j])
  for place in sc.places:
    if not c.rules and place in c.strs: continue
    for s in c.slots[place]:
      let k = slotKey(place, s)
      let cans = c.st.getOrDefault(k, {cLive})
      if cLive in cans: c.report("leak", cans, shown(k), c.declAt[place])
      else: c.clean.incl c.keyOf("leak", shown(k), c.declAt[place])

proc leave(c: var Check, depth: int) =
  ## A way out: every scope opened at `depth` or deeper ends, innermost first.
  for i in countdown(c.scopes.high, depth): c.close(i)

proc outerOnly(c: Check, depth: int): State =
  ## This path's state without the places scopes from `depth` on declared:
  ## what reaches a point outside them.
  result = c.st
  for i in depth .. c.scopes.high:
    for place in c.scopes[i].places:
      for s in c.slots[place]: result.del slotKey(place, s)

# --- the walk -----------------------------------------------------------------

proc walkExpr(c: var Check, e: Expr, use: Use)

proc boundType(c: Check, n: Expr): Type =
  ## The type a binding gives its new place: the checker's first, since a
  ## written annotation need not carry the declaration edge.
  if c.res.typeFor(n.target) != nil: c.res.typeFor(n.target)
  elif c.res.typeFor(n.assignVal) != nil: c.res.typeFor(n.assignVal)
  else: n.declType

proc overwrite(c: var Check, n: Expr, keys: seq[string]) =
  ## An owned place or field takes a new value. The old one must have been
  ## moved out, or is dropped first (`dropsOld`).
  for k in keys:
    if n.dropsOld: c.dropSlot(k)
    elif not c.isStrSlot(k):
      let cans = c.st.getOrDefault(k, {cLive})
      if cLive in cans: c.report("overwrite-leak", cans, shown(k), n.span)
  for k in keys: c.st[k] = {cLive}

proc walkAssign(c: var Check, n: Expr) =
  ## The value is evaluated (and may move things), then the place is
  ## defined: a new owned place, or an owned place or field losing its old
  ## value, which must have been moved out or is dropped (`dropsOld`).
  let (outer, outerPlace) = (c.threaded, c.refills)
  c.threaded = threadedCall(n)
  c.refills = if n.target != nil: pathOf(n.target) else: ""
  c.walkExpr(n.assignVal, uSink)
  (c.threaded, c.refills) = (outer, outerPlace)
  let t = n.target
  if c.dead or t == nil: return
  if t.kind == exkVar and t.name notin c.slots and t.name notin c.borrowed:
    if not c.res.isOwnerField(t): c.declare(t.name, c.boundType(n), n.span)
  else: c.overwrite(n, c.keysOf(pathOf(t)))

proc walkBlock(c: var Check, b: Expr, use: Use) =
  ## A scope: its statements in order, then its end.
  c.scopes.add Scope()
  for i, s in b.stmts:
    if c.dead: break
    c.walkExpr(s, if i == b.stmts.high: use else: uNone)
  if not c.dead: c.close(c.scopes.high)
  let sc = c.scopes.pop()
  for place in sc.places:
    for s in c.slots[place]: c.st.del slotKey(place, s)
    c.slots.del place
    c.strs.excl place

proc walkArms(c: var Check, arms: seq[Expr], use: Use, mayFallThrough: bool) =
  ## Alternatives from one state, joined where they meet. `mayFallThrough`:
  ## no arm may run at all.
  let entry = c.st
  var joined: State
  var any = mayFallThrough
  if mayFallThrough: joined = entry
  for arm in arms:
    c.st = entry
    c.dead = false
    c.walkExpr(arm, use)
    if c.dead: continue
    if any: joined.joinInto(c.st) else: joined = c.st
    any = true
  c.st = joined
  c.dead = not any

proc walkMatch(c: var Check, e: Expr, use: Use) =
  ## The subject is borrowed; checked closed-domain matches have no
  ## fallthrough edge. Open-domain partial matches still have one.
  c.step(e.subject, uBorrow)
  var bodies: seq[Expr]
  for arm in e.arms:
    bodies.add arm.body
  c.walkArms(bodies, use, not c.res.checkedMatchIsExhaustive(e))

proc walkSelect(c: var Check, e: Expr) =
  ## `on select`: every arm's source is read; one arm's body runs.
  for arm in e.selArms: c.step(arm.arg, uBorrow)
  var bodies: seq[Expr]
  for arm in e.selArms: bodies.add arm.body
  c.walkArms(bodies, uNone, false)

proc walkLoop(c: var Check, cond, body: Expr) =
  ## The loop's head is where its entry and every way back meet; the body is
  ## walked until that state stops growing. The loop is left at its head
  ## (the condition fails, or the iterable runs out) or at a `break`.
  var head = c.st
  var after: State
  for round in 0 .. 8:
    c.st = head
    c.dead = false
    c.step(cond, uBorrow)
    after = c.st
    c.loops.add Loop(depth: c.scopes.len)
    c.walkExpr(body, uNone)
    let lp = c.loops.pop()
    var next = head
    if not c.dead: next.joinInto(c.st)
    if lp.anyCont: next.joinInto(lp.cont)
    if lp.anyBrk: after.joinInto(lp.brk)
    if next == head: break
    head = next
  c.st = after
  c.dead = false

proc walkJump(c: var Check, e: Expr) =
  ## `break` / `continue`: the loop body's scopes end, and this path's state
  ## goes to where the jump lands.
  if c.loops.len == 0: return
  let depth = c.loops[^1].depth
  c.leave(depth)
  let st = c.outerOnly(depth)
  if e.kind == exkBreak:
    if c.loops[^1].anyBrk: c.loops[^1].brk.joinInto(st)
    else: c.loops[^1].brk = st
    c.loops[^1].anyBrk = true
  else:
    if c.loops[^1].anyCont: c.loops[^1].cont.joinInto(st)
    else: c.loops[^1].cont = st
    c.loops[^1].anyCont = true
  c.dead = true

proc walkExit(c: var Check, e: Expr) =
  ## `return` / `raise`: its value is handed over, then every scope ends.
  c.step(e, uNone)
  c.leave(0)
  c.dead = true

proc walkExpr(c: var Check, e: Expr, use: Use) =
  ## One statement or value, in the order it runs. Control flow is walked;
  ## everything else is one expression evaluated (`step`).
  if e == nil or c.dead: return
  case e.kind
  of exkBlock: c.walkBlock(e, use)
  of exkIf:
    c.step(e.cond, uBorrow)
    c.walkArms(@[e.thenBranch, e.elseBranch], use, e.elseBranch == nil)
  of exkMatch: c.walkMatch(e, use)
  of exkSelect: c.walkSelect(e)
  of exkFor:
    c.step(e.iterable, uBorrow)
    c.walkLoop(nil, e.body)
  of exkWhile: c.walkLoop(e.whileCond, e.whileBody)
  of exkAssign: c.walkAssign(e)
  of exkReturn, exkRaise: c.walkExit(e)
  of exkBreak, exkContinue: c.walkJump(e)
  of exkDefer: c.deferDrops(e)
  of exkReset:
    for k in c.keysOf(pathOf(e.resetPlace)): c.st[k] = {cLive}
  of exkLit, exkVar, exkField, exkQualified, exkStruct, exkList, exkFill,
     exkBracket, exkBracketAssign, exkCall, exkChain, exkBinary, exkUnary,
     exkDiscard, exkTripleDot, exkImport, exkSend, exkAcquire, exkFinish,
     exkActorRef, exkRegisterRef, exkRegistryRef, exkPoolRef, exkMixinRef,
     exkSlabRef, exkArenaRef, exkCombinator, exkOrdinal, exkValidate,
     exkIfaceCall, exkIfaceIs, exkIfacePayload, exkWrapOk, exkAbsent,
     exkPoolOp, exkSlabOp, exkSlabCell, exkArenaReset, exkAppend, exkCopy,
     exkDrop, exkMove:
    c.step(e, use)

proc checkFn(res: Resolution, m: Module, d: Decl): seq[string] =
  ## Rule V over one fn's body, under the twins' convention.
  var c = Check(res: res, m: m, fn: d.name, rules: RulesMode)
  c.scopes.add Scope()
  if "self" notin d.fnParams.mapIt(it.name): c.borrowed.incl "self"
  let moved = movedFnParam(res, m, d)
  for p in d.fnParams:
    let owns = if c.rules: p.consumes
               else: p.name == moved
    let typ = if c.rules: ownershipParamType(d, p.typ) else: p.typ
    if owns and ownsHeap(m, typ): c.declare(p.name, typ, d.fnBody.span)
    else: c.borrowed.incl p.name
  c.walkExpr(d.fnBody, uSink)
  if not c.dead: c.leave(0)
  for key, certain in c.found:
    let parts = key.split('\t')
    let some = not certain or key in c.clean
    result.add "VERIFY " & parts[0] & (if some: " (some paths)" else: "") &
               " " & parts[1]

let DebugVerify = getEnv("TUCK_DEBUG_OWN") == "verify"
  ## Read once at module init.

proc verifyTree*(res: Resolution, m: Module) =
  ## Independent rule V runs on the common tree before any backend clone.
  ## Debug mode also prints findings for legacy differential tests.
  if not RulesMode and not DebugVerify: return
  for d in m.ownershipFns:
    if d == nil or d.fnBody == nil: continue
    let findings = checkFn(res, m, d)
    if DebugVerify:
      for line in findings: echo line
    if RulesMode:
      doAssert findings.len == 0,
        "ownership verification failed before backend emission:\n" & findings.join("\n")
