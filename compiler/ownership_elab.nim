# compiler/ownership_elab.nim
#
# THE ELABORATOR — Stage D of the ownership rules
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §2, §5).
#
# It computes, from the rules alone, the decisions the passes it replaces
# compute today: which parameters consume (P), which sinks move and which
# copy (S), where each owned place is dropped (D) and reset (M). It runs in
# SHADOW MODE first — beside today's passes, deciding nothing that is
# printed — so every difference between the two can be explained before
# anything switches (`ownership_shadow`).
#
# Every question starts from rule U's classifier (`ownership_rules`): what a
# read IS (borrow, sink, an argument) is decided there once, per node kind.
#
# RULE P — a parameter is consuming iff some final read of it (or of a path
# through it) is a sink. An argument is a sink when the parameter it feeds
# consumes, so the answer is the least fixed point over the call graph: a
# call back into a question still being answered reads as "borrows", which
# is what a recursive reader is. A read that cannot carry the parameter's
# storage away — a scalar field, `b.count` — is never a sink of it.
#
# A CALLEE WITH NO BODY (the runtime, an FFI extern, a `pending:` stub)
# cannot be read, so what it does is a CONTRACT, the same for every such
# callee and named nowhere in the compiler. It is read off the types at the
# call (see "What a body-less callee does" below), and the runtime is
# written to keep it.
import os, tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules
from ssa_ir import rootOf
from twin_shape import ownsHeap, seqFieldNames
import ownership_glue

let RulesMode* = getEnv("TUCK_OWN") != "legacy"
  ## Common ownership is the default on every backend. The explicit legacy
  ## setting exists only for differential regressions and rollback.

type ConsumeMemo* = object
  ## Rule P's answers so far, and the questions being answered (a recursive
  ## call into one reads as "borrows").
  known: Table[string, bool]
  busy: HashSet[string]

proc calleeOf*(res: Resolution, m: Module, call: Expr): Decl =
  ## The fn a call reaches: as the checker resolved it, else by name (calls
  ## that lowering built carry no resolution of their own).
  result = res.declFor(call)
  if result == nil and call.callee != nil and call.callee.kind == exkVar:
    result = m.findFn(call.callee.name)
  result = ownershipFunction(result)

# --- WHAT A BODY-LESS CALLEE DOES, FROM ITS SIGNATURE --------------------------
#
# The contract, for any callee with no Tuck body. "Inside" is STRICT: a
# part of the type, not the type itself.
#   - it TAKES an owning argument whose type sits inside its result (it is
#     stored there), or, when the result cannot hold it at all, inside
#     another argument (it is stored into that one). It keeps it, or frees
#     it.
#   - it only READS every other argument. One whose type IS the result's is
#     read: the result is a new value of that type.
#   - an owning RESULT whose type sits inside an argument it only reads is a
#     VIEW of that argument: the caller copies it where it keeps it and never
#     drops it. Any other owning result is FRESH: the caller's to drop.
# The types are the ones the checker recorded at this call, so a generic
# extern is judged per use. The runtime keeps the contract as written:
# `push` reads its `items` (it returns a new Seq) and takes the `value` it
# stores, `setAt` takes the value it stores, `at` returns a view of the
# element. A new extern keeps it too; nothing here names a callee.

proc keyOf(t: Type, sub: Table[string, string]): string =
  ## A type, spelled so two equal types spell the same: names resolved
  ## through `sub` (a generic's parameters to the call's arguments).
  if t == nil: return "?"
  case t.kind
  of tkNamed: result = sub.getOrDefault(t.name, t.name)
  of tkApp:
    result = keyOf(t.base, sub) & "["
    for i, a in t.args:
      if i > 0: result.add ","
      result.add keyOf(a, sub)
    result.add "]"
  of tkTuple, tkFunc, tkRecord, tkSum, tkUnion, tkEffect, tkRename:
    result = $t.kind & "#" & $t.id.uint32

type Part = tuple[t: Type, sub: Table[string, string]]

proc fieldParts(body: Type, sub: Table[string, string]): seq[Part] =
  ## The field types of a record or of a sum's variants.
  if body == nil: return
  case body.kind
  of tkRecord:
    for f in body.fields: result.add (f.typ, sub)
  of tkSum:
    for v in body.variants:
      for f in v.fields: result.add (f.typ, sub)
  of tkNamed, tkTuple, tkApp, tkFunc, tkUnion, tkEffect, tkRename:
    result.add (body, sub)

proc declOfType(res: Resolution, m: Module, t: Type): Decl =
  ## The `type` declaration a named type refers to, or nil.
  result = res.declForType(t)
  if result == nil and t.kind == tkNamed: result = m.findDecl(dkType, t.name)
  if result != nil and result.kind != dkType: result = nil

proc partsOf(res: Resolution, m: Module, p: Part): seq[Part] =
  ## The types a value of `p.t` is made of, one level down: a Seq's element,
  ## a `?`/`!` payload, a generic's arguments, a record's or sum's fields
  ## (a generic one's with its parameters substituted).
  let t = p.t
  if t == nil: return
  case t.kind
  of tkApp:
    for a in t.args: result.add (a, p.sub)
    let d = if t.base != nil: res.declOfType(m, t.base) else: nil
    if d != nil:
      var sub = initTable[string, string]()
      for i, g in d.generics:
        if i < t.args.len: sub[g] = keyOf(t.args[i], p.sub)
      result.add fieldParts(d.typeBody, sub)
  of tkNamed:
    if t.name notin p.sub:
      let d = res.declOfType(m, t)
      if d != nil and d.generics.len == 0: result.add fieldParts(d.typeBody, p.sub)
  of tkRecord, tkSum: result.add fieldParts(t, p.sub)
  of tkTuple:
    for e in t.elems: result.add (e, p.sub)
  of tkFunc, tkUnion, tkEffect, tkRename: discard

proc holds(res: Resolution, m: Module, outer: Part, inner: string,
           strict = false, depth = 0): bool =
  ## Is `inner` (a key) the type `outer`, or a part of it at any depth?
  ## `strict`: a part only, not `outer` itself.
  if not strict and keyOf(outer.t, outer.sub) == inner: return true
  if depth > 6: return false
  for part in res.partsOf(m, outer):
    if res.holds(m, part, inner, false, depth + 1): return true
  false

proc argsOf(call: Expr): seq[Expr] =
  ## A call's arguments, in the order `uses` gives them (rule U).
  let payload = payloadOf(call)
  if payload != nil:
    for f in payload.fields: result.add f.value
  else: result = call.args

proc typeAt(res: Resolution, e: Expr): Part =
  (res.typeFor(e), initTable[string, string]())

proc bodylessKeeps*(res: Resolution, m: Module, call: Expr, index: int): bool =
  ## The contract: does a body-less callee take its `index`-th argument? It
  ## does when the argument owns heap and its type can sit inside the result
  ## or inside another argument. A result whose type is unknown is taken to
  ## hold it (the caller then hands it over; it never frees it under a
  ## callee that keeps it).
  let args = argsOf(call)
  if index < 0 or index >= args.len or args[index] == nil: return false
  let t = res.typeFor(args[index])
  if not ownsHeap(m, t): return false
  let k = keyOf(t, initTable[string, string]())
  let r = res.typeFor(call)
  if r == nil: return true
  let made = (r, initTable[string, string]())
  if res.holds(m, made, k, strict = true): return true    # stored in it
  if res.holds(m, made, k): return false     # the result is a new one of it
  for j, other in args:
    if j != index and other != nil and
       res.holds(m, res.typeAt(other), k, strict = true):
      return true                            # stored into another argument
  false

proc resultIsView*(res: Resolution, m: Module, call: Expr, t: Type): bool =
  ## The contract: is a body-less callee's owning result (of type `t`) a view
  ## of an argument it only reads?
  if not ownsHeap(m, t): return false
  let k = keyOf(t, initTable[string, string]())
  # Equal argument/result types promise a fresh result. This takes priority
  # over containment in another argument (e.g. joining Seq[str] with str).
  for i, a in argsOf(call):
    if a != nil and not res.bodylessKeeps(m, call, i) and
       keyOf(res.typeFor(a), initTable[string, string]()) == k:
      return false
  for i, a in argsOf(call):
    if a != nil and not res.bodylessKeeps(m, call, i) and
       res.holds(m, res.typeAt(a), k, strict = true):
      return true
  false

proc paramFed(d: Decl, a: ArgOf): string =
  ## The name of the parameter of `d` the argument `a` feeds, or "".
  if a.name.len > 0: return a.name
  if a.index >= 0 and a.index < d.fnParams.len: d.fnParams[a.index].name
  else: ""

type ArgTarget* = tuple[callee: Decl, name, param: string]
  ## Where an argument goes: the fn it reaches (nil for one with no
  ## declaration), that fn's name, and the parameter it feeds ("" when
  ## unknown).

proc argTarget*(res: Resolution, m: Module, a: ArgOf): ArgTarget =
  ## Where the argument `a` goes (`a.call` is not nil).
  let callee = res.calleeOf(m, a.call)
  let name = if callee != nil: callee.name
             elif a.call.callee != nil and a.call.callee.kind == exkVar:
               a.call.callee.name
             else: ""
  let p = if callee != nil: paramFed(callee, a) else: a.name
  (callee, name, p)

proc bodyless*(t: ArgTarget): bool =
  ## Is the callee one with no Tuck body to read (or no parameter known)?
  t.callee == nil or t.callee.fnBody == nil or t.param.len == 0

proc consumes*(res: Resolution, m: Module, d: Decl, pname: string,
               memo: var ConsumeMemo): bool

proc argConsumesWhy*(res: Resolution, m: Module, a: ArgOf,
                    memo: var ConsumeMemo): string =
  ## Why the parameter this argument feeds consumes it, or "" if it borrows.
  if a.call == nil: return "an unresolved call"   # `.name {args}` left as is
  let t = res.argTarget(m, a)
  if t.bodyless:
    if res.bodylessKeeps(m, a.call, a.index):
      return t.name & " has no body, and its signature lets it keep it"
    return ""
  if res.consumes(m, t.callee, t.param, memo): t.name & " keeps it" else: ""

proc consumesWhy*(res: Resolution, m: Module, d: Decl, pname: string,
                  memo: var ConsumeMemo): string =
  ## Rule P with its reason: the first final read of `pname` that is a sink,
  ## named, or "" when `d` only borrows it. Not memoised; `consumes` is.
  if d.fnBody == nil: return ""
  for pu in res.placeUsesOf(d.fnBody):
    if rootOf(pu.path) != pname or not res.isLastUse(pu.read): continue
    if not ownsHeap(m, res.typeFor(pu.read)): continue   # carries nothing
    let at = " at " & $pu.read.span.line & ":" & $pu.read.span.col
    if pu.use == uSink: return "a sink" & at
    if pu.use == uArg:
      let why = res.argConsumesWhy(m, pu.arg, memo)
      if why.len > 0: return why & at
  ""

proc consumes*(res: Resolution, m: Module, d: Decl, pname: string,
               memo: var ConsumeMemo): bool =
  ## Rule P: does `d` consume its parameter `pname`? The least fixed point:
  ## a question asked again while it is being answered reads as "borrows".
  if d.ownershipElaborated:
    for p in d.fnParams:
      if p.name == pname: return p.consumes
    return false
  let key = $d.id.uint32 & "\0" & d.name & "\0" & pname
  if key in memo.known: return memo.known[key]
  if key in memo.busy: return false
  memo.busy.incl key
  result = res.consumesWhy(m, d, pname, memo).len > 0
  memo.busy.excl key
  memo.known[key] = result

# --- RULES D AND M: where each owned place is dropped -----------------------
#
# D: every owned place is dropped once, at the end of its scope, on every
# path. M: a move out of a place still to be dropped resets it, so the drop
# frees nothing there. What is decided here, per owned SLOT (the granularity
# today's pass frees at — the value itself for a Seq or a str, a record's
# Seq fields by name), is each place's FATE where its scope ends:
#
#   fOwned   it still holds what it owns on every path: dropped there
#   fMoved   it was moved out on every path: nothing is left to drop
#   fMaybe   moved on some paths and not others: dropped there, and reset
#            where it was moved (M) — the case a name-level analysis cannot
#            see, and the one today's pass answers by never freeing it
#
# and, at every reassignment of an owned place, the fate of the value it is
# about to lose (dropped first unless it was moved out).
#
# The walk follows control flow: an `if`'s or a `match`'s arms are walked
# from the same state and joined; a loop may run no times, so its body's
# end joins its entry; a `return` ends every open scope, a `break` or
# `continue` every scope inside its loop. A move is a final read (the SSA
# mirror's stamp, which is per path) put to a sink (rule S), or handed to a
# consuming parameter (rule P).

type
  Fate* = enum
    fOwned, fMoved, fMaybe
  DropPlan* = object
    scopeEnd*: Table[string, Fate]
      ## `place & "\t" & slot` -> its fate where its scope ends, joined over
      ## every way out of the scope
    overwrite*: Table[NodeId, Fate]
      ## a reassignment of an owned place -> the old value's fate
    strs*: HashSet[string]
      ## the owned places that are a `str`: dropping one on Odin waits on
      ## rule G (a literal is static storage, never to be freed)
    moves*: Table[string, seq[Expr]]
      ## slot key -> the reads that move it out: where rule M resets a
      ## `maybe` place
  State = Table[string, Fate]
  DropWalk = object
    res: Resolution
    m: Module
    memo: ConsumeMemo
    slots: Table[string, seq[string]]  ## owned place -> its slots
    scopes: seq[seq[string]]           ## the owned places each open block declared
    loops: seq[int]                    ## scopes.len where each open loop's body began
    st: State                          ## the current path's fates
    dead: bool                         ## the current path has left its block
    plan: DropPlan

proc slotsOf*(res: Resolution, m: Module, t: Type): seq[string] =
  ## What a value of type `t` owns, slot by slot: "" for a Seq or a str (the
  ## value itself), else a record's Seq fields by name.
  if t == nil: return
  if RulesMode:
    for slot in owningSlots(m, t): result.add slot.path
    return
  if seqElem(t) != nil or isStr(t): return @[""]
  seqFieldNames(res, m, t)

proc slotKey*(place, slot: string): string = place & "\t" & slot

proc join(a, b: Fate): Fate =
  if a == b: a else: fMaybe

proc joinInto(dst: var State, src: State) =
  ## Paths meet: a slot both left owned stays owned, both moved stays moved.
  for k, f in src:
    dst[k] = if k in dst: join(dst[k], f) else: f

proc endScopeOf(w: var DropWalk, place: string) =
  ## `place`'s scope ends on this path: its fates join its scope-end record.
  for s in w.slots[place]:
    let k = slotKey(place, s)
    let f = w.st.getOrDefault(k, fOwned)
    w.plan.scopeEnd[k] = if k in w.plan.scopeEnd: join(w.plan.scopeEnd[k], f)
                         else: f

proc endScopesFrom(w: var DropWalk, depth: int) =
  ## Every scope opened at `depth` or deeper ends on this path.
  for i in depth ..< w.scopes.len:
    for place in w.scopes[i]: w.endScopeOf(place)

proc sinksAway(w: var DropWalk, pu: PlaceUse): bool =
  ## Is this read a move: put to a sink, or handed to a consuming parameter?
  pu.use == uSink or
    (pu.use == uArg and w.res.argConsumesWhy(w.m, pu.arg, w.memo).len > 0)

proc applyMoves(w: var DropWalk, e: Expr, use: Use) =
  ## Every final read under `e` that sinks an owned place moves it (S).
  for pu in w.res.placeUsesUnder(e, use):
    let root = rootOf(pu.path)
    if root notin w.slots or not w.res.isLastUse(pu.read): continue
    if not ownsHeap(w.m, w.res.typeFor(pu.read)) or not w.sinksAway(pu):
      continue
    var keys: seq[string]
    if pu.path == root:
      for s in w.slots[root]: keys.add slotKey(root, s)
    else:
      let path = pu.path[root.len + 1 .. ^1]
      for s in w.slots[root]:
        if s == path or s.startsWith(path & "."): keys.add slotKey(root, s)
    for k in keys:
      w.st[k] = fMoved
      w.plan.moves.mgetOrPut(k, @[]).add pu.read

proc oldFate(w: DropWalk, place: string): Fate =
  ## The fate of what an owned place holds now, over all its slots.
  result = fMoved
  var first = true
  for s in w.slots[place]:
    let f = w.st.getOrDefault(slotKey(place, s), fOwned)
    result = if first: f else: join(result, f)
    first = false

proc declare(w: var DropWalk, place: string, t: Type) =
  ## An owned place begins here, holding what it was given.
  let ss = slotsOf(w.res, w.m, t)
  if ss.len == 0: return
  w.slots[place] = ss
  w.scopes[^1].add place
  if isStr(t): w.plan.strs.incl place
  for s in ss: w.st[slotKey(place, s)] = fOwned

proc walkExpr(w: var DropWalk, e: Expr, use: Use)

proc overwriteField(w: var DropWalk, n: Expr, path: string) =
  ## `b.items = v`: one owned slot of an owned record loses its old value.
  let root = rootOf(path)
  if root notin w.slots or path.len <= root.len: return
  let path = path[root.len + 1 .. ^1]
  var fate = fMoved
  var any = false
  for s in w.slots[root]:
    if s != path and not s.startsWith(path & "."): continue
    let k = slotKey(root, s)
    fate = if any: join(fate, w.st.getOrDefault(k, fOwned))
           else: w.st.getOrDefault(k, fOwned)
    any = true
    w.st[k] = fOwned
  if any: w.plan.overwrite[n.id] = fate

proc walkAssign(w: var DropWalk, n: Expr) =
  ## The value is evaluated (and may move things), then the place is
  ## defined: a new owned place, or an owned place losing its old value.
  w.walkExpr(n.assignVal, uSink)
  let t = n.target
  if t == nil: return
  if w.res.isOwnerField(t):
    if RulesMode and ownsStorage(w.m, w.res.typeFor(t)):
      # Actor reads are copied at sinks, never moved out of singleton state.
      w.plan.overwrite[n.id] = fOwned
    return
  if t.kind == exkField:
    var base = t
    while base != nil and base.kind == exkField: base = base.receiver
    if RulesMode and base != nil and base.kind == exkSlabCell and
       ownsStorage(w.m, w.res.typeFor(t)):
      w.plan.overwrite[n.id] = fOwned
      return
    w.overwriteField(n, pathOf(t))
    return
  if t.kind != exkVar: return
  if t.name in w.slots:
    w.plan.overwrite[n.id] = w.oldFate(t.name)
    for s in w.slots[t.name]: w.st[slotKey(t.name, s)] = fOwned
  else:
    # The checker's type first: a written annotation (`var b: Builder`) is
    # a parsed node that need not carry the declaration edge.
    let ty = if w.res.typeFor(t) != nil: w.res.typeFor(t)
             elif w.res.typeFor(n.assignVal) != nil: w.res.typeFor(n.assignVal)
             else: n.declType
    w.declare(t.name, ty)

proc walkBlock(w: var DropWalk, b: Expr, use: Use) =
  ## A scope: its statements in order, then the end of its places' scope.
  w.scopes.add @[]
  for i, s in b.stmts:
    if w.dead: break
    w.walkExpr(s, if i == b.stmts.high: use else: uNone)
  if not w.dead:
    for place in w.scopes[^1]: w.endScopeOf(place)
  for place in w.scopes[^1]:
    for s in w.slots[place]: w.st.del slotKey(place, s)
    w.slots.del place
  discard w.scopes.pop()

proc walkArms(w: var DropWalk, arms: seq[Expr], use: Use, mayFallThrough: bool) =
  ## Alternatives from one state, joined where they meet; `mayFallThrough`:
  ## no arm may run at all (an `if` without `else`, a partial match).
  let entry = w.st
  var joined: State
  var any = false
  if mayFallThrough:
    joined = entry
    any = true
  for arm in arms:
    w.st = entry
    w.dead = false
    w.walkExpr(arm, use)
    if w.dead: continue
    if any: joined.joinInto(w.st) else: joined = w.st
    any = true
  w.st = joined
  w.dead = not any

proc walkLoop(w: var DropWalk, head, body: Expr) =
  ## The body may run no times: its end joins its entry.
  if head != nil: w.applyMoves(head, uBorrow)
  let entry = w.st
  w.loops.add w.scopes.len
  w.walkExpr(body, uNone)
  discard w.loops.pop()
  var after = entry
  if not w.dead: after.joinInto(w.st)
  w.st = after
  w.dead = false

proc walkExit(w: var DropWalk, e: Expr, depth: int) =
  ## A way out: what it returns is evaluated, then every scope it leaves ends.
  if e.kind in {exkReturn, exkRaise}:
    w.applyMoves(e, uNone)
  w.endScopesFrom(depth)
  w.dead = true

proc walkExpr(w: var DropWalk, e: Expr, use: Use) =
  ## One statement or value, in the order it runs.
  if e == nil: return
  case e.kind
  of exkBlock: w.walkBlock(e, use)
  of exkIf:
    w.applyMoves(e.cond, uBorrow)
    w.walkArms(@[e.thenBranch, e.elseBranch], use, e.elseBranch == nil)
  of exkMatch:
    w.applyMoves(e.subject, uBorrow)
    var bodies: seq[Expr]
    for arm in e.arms:
      bodies.add arm.body
    w.walkArms(bodies, use, not w.res.checkedMatchIsExhaustive(e))
  of exkFor: w.walkLoop(e.iterable, e.body)
  of exkWhile: w.walkLoop(e.whileCond, e.whileBody)
  of exkAssign: w.walkAssign(e)
  of exkReturn, exkRaise: w.walkExit(e, 0)
  of exkBreak, exkContinue:
    w.walkExit(e, if w.loops.len > 0: w.loops[^1] else: w.scopes.len)
  of exkDefer: discard          # runs at the scope's end, reading only
  else: w.applyMoves(e, use)

proc dropPlan*(res: Resolution, m: Module, d: Decl): DropPlan =
  ## Rules D and M for one fn: its owned locals, and its consuming
  ## parameters (P), each with its fate where its scope ends.
  if d.fnBody == nil: return
  var w = DropWalk(res: res, m: m)
  w.scopes.add @[]
  for p in d.fnParams:
    let typ = ownershipParamType(d, p.typ)
    if ownsHeap(m, typ) and res.consumes(m, d, p.name, w.memo):
      w.declare(p.name, typ)
  w.walkExpr(d.fnBody, uSink)
  if not w.dead:
    for place in w.scopes[0]: w.endScopeOf(place)
  w.plan

# --- RULE S: which bindings copy ----------------------------------------------
#
# A sink moves at the final use of an owned place, and copies otherwise. At
# a binding `x = v` that means: `v` a read of a place this body owns (a
# local, or a consuming parameter) moves when the read is final and copies
# when it is not; a read of anything it does not own (a borrowing parameter,
# an actor's field) always copies; a temporary (a call's result, a literal)
# is the binding's already and never copies. A construction's fields are
# sinks of their own, so `{items: xs} Bag` copies `items` exactly when `xs`
# would be copied bound alone. (A call's result needs no provenance
# question: if the callee returned a parameter it only borrowed, rule S
# copied it inside the callee.)

type CopyAt* = tuple[whole: bool, fields: seq[string]]
  ## What a binding copies: its whole value, or these fields of a record.

type Places* = object
  ## A body's places: every parameter and local, and the ones it owns.
  all, owned: HashSet[string]
  m: Module

proc placesOf*(res: Resolution, m: Module, d: Decl,
              memo: var ConsumeMemo): Places =
  ## Every parameter and every local a body binds; it owns the locals and
  ## its consuming parameters.
  result.m = m
  for p in d.fnParams:
    result.all.incl p.name
    if ownsHeap(m, ownershipParamType(d, p.typ)) and res.consumes(m, d, p.name, memo):
      result.owned.incl p.name
  for n in d.fnBody.nodes:
    if n.kind == exkAssign and n.target != nil and n.target.kind == exkVar and
       not res.isOwnerField(n.target):
      result.all.incl n.target.name
      result.owned.incl n.target.name

proc readsElement*(res: Resolution, m: Module, v: Expr): bool =
  ## A read of something another value holds, not a fresh value: `items[i]`
  ## (rule U: an element is never moved out of its container), or a call
  ## to a body-less callee whose result is a view of an argument (the
  ## contract above). A sink of one copies it.
  if v.kind == exkBracket: return true
  if v.kind == exkSlabOp and v.slabOp == soGet: return true
  var base = v
  while base != nil and base.kind == exkField: base = base.receiver
  if base != nil and base.kind == exkSlabCell: return true
  let call = if v.kind == exkCall: v elif res.hasCall(v): res.call(v) else: nil
  if call == nil or call.kind != exkCall: return false
  let d = res.calleeOf(m, call)
  (d == nil or d.fnBody == nil) and res.resultIsView(m, call, res.typeFor(v))

proc copiesRead*(res: Resolution, ps: Places, v: Expr): bool =
  ## Rule S at one sink: does putting `v` there copy it? A read of a PLACE
  ## does unless it is the owned place's final use; so does an element read.
  ## Anything else is a temporary and moves: `Expr.Num {..}`, `State.Ready`
  ## or a nullary fn look like paths and are values built on the spot.
  if v != nil and res.readsElement(ps.m, v): return true
  if v == nil or not res.isPlaceRead(v):
    return false                                   # a temporary moves
  if res.isOwnerField(v): return true              # an actor's field
  if isSingletonRead(v): return true
  let root = rootOf(pathOf(v))
  if root notin ps.all: return RulesMode           # static/global borrowed value
  root notin ps.owned or not res.isLastUse(v)

proc fieldCopies(res: Resolution, m: Module, ps: Places, v: Expr): seq[string] =
  ## A construction's Seq fields that copy what they are given.
  if v.kind != exkCall or v.args.len != 1 or v.args[0] == nil or
     v.args[0].kind != exkStruct:
    return
  let fs = seqFieldNames(res, m, res.typeFor(v))
  for f in v.args[0].fields:
    if f.name in fs and res.copiesRead(ps, f.value): result.add f.name

proc copyAt(res: Resolution, m: Module, ps: Places, v: Expr): CopyAt =
  ## What binding `v` copies: the whole value, or a record's fields. A whole
  ## record's copy IS the copy of its Seq fields, which is how a record's
  ## copy is spelled (cpFields).
  let t = res.typeFor(v)
  if not res.copiesRead(ps, v): return (false, res.fieldCopies(m, ps, v))
  let fs = seqFieldNames(res, m, t)
  if seqElem(t) == nil and fs.len > 0: (false, fs) else: (true, @[])

proc copyPlan*(res: Resolution, m: Module, d: Decl): Table[NodeId, CopyAt] =
  ## Rule S for every binding in one fn that copies anything.
  if d.fnBody == nil: return
  var memo: ConsumeMemo
  let ps = res.placesOf(m, d, memo)
  for n in d.fnBody.nodes:
    if n.kind != exkAssign or n.assignVal == nil: continue
    if not ownsHeap(m, res.typeFor(n.assignVal)): continue
    let at = res.copyAt(m, ps, n.assignVal)
    if at.whole or at.fields.len > 0: result[n.id] = at
