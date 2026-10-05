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
# A CALLEE WITH NO BODY to ask is answered by THE RUNTIME TABLE below when
# it is the runtime's: only `push` and `setAt` keep an argument, the value
# they store (and so do the compiler's own `tuckSetAt` / `tuckArraySetAt`);
# every other runtime
# extern and helper reads its arguments and returns fresh values. An extern
# the table does not know — foreign code a program links — is taken to
# consume: that is the safe answer (the caller hands over a value it will
# not touch again, moving a dead one and copying a live one), and the one
# `codegen_common.keptAt` gives every body-less callee today.
import os, tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules
from ssa_ir import rootOf
from twin_shape import ownsHeap, seqFieldNames

let RulesMode* = getEnv("TUCK_OWN") == "rules"
  ## Read once at module init: the rules write the Odin tree
  ## (ownership_write), and rule V checks it under rule P's convention.

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
  if result != nil and result.kind != dkFn: result = nil

type Keeps* = enum
  kUnknown  ## not the runtime's: a fn with a body to ask, or foreign code
  kBorrows  ## the runtime reads it and returns fresh values
  kKeeps    ## the runtime stores it (`push`, `setAt`)

const
  RuntimeKeeps = [("push", "value"), ("setAt", "value")]
    ## The runtime externs' parameters that KEEP their argument: `push` and
    ## `setAt` store `value`. `push` only READS `items`: it returns a new
    ## Seq on every backend (Nim `result = items` from a non-sink parameter,
    ## D `items ~ [value]`, Odin a fresh buffer), and `xs = push(xs, v)`,
    ## the one shape that grows in place, is `exkAppend` before this asks.
  HelperKeeps = [("tuckSetAt", 2), ("tuckArraySetAt", 2)]
    ## The same for the helpers the compiler introduces (positional: no
    ## declaration names their parameters): the stored value.
  RuntimeNames = ["at", "setAt", "push", "count", "len", "toStr", "charAt",
                  "containsChar", "splitLines", "ord", "joinStr", "byteAt",
                  "byteCount", "parseFloat", "fromBytes", "print",
                  "printLine", "readFile", "writeFile", "appendFile",
                  "fileExists", "removeFile", "makeDir", "hash", "sqrt",
                  "pow", "send", "connect", "recv", "getEnv",
                  "tuckAt", "tuckSetAt", "tuckArrayAt", "tuckArraySetAt",
                  "tuckConcat", "tuckSat", "tuckSatI", "tuckSeqBounds",
                  "tuckSeqCopy"]
    ## Every runtime callee that can be handed an owning value. Unmangled:
    ## a user fn of the same name is `tuckˑfnˑ…` by the time this runs.

proc runtimeKeeps(callee: string, param: string, index: int): Keeps =
  ## What the runtime does with an argument, or kUnknown for a callee that
  ## is not the runtime's.
  if callee notin RuntimeNames: return kUnknown
  for (fn, p) in RuntimeKeeps:
    if fn == callee and p == param: return kKeeps
  for (fn, i) in HelperKeeps:
    if fn == callee and i == index: return kKeeps
  kBorrows

proc paramFed(d: Decl, a: ArgOf): string =
  ## The name of the parameter of `d` the argument `a` feeds, or "".
  if a.name.len > 0: return a.name
  if a.index >= 0 and a.index < d.fnParams.len: d.fnParams[a.index].name
  else: ""

type ArgTarget* = tuple[callee: Decl, name, param: string, runtime: Keeps]
  ## Where an argument goes: the fn it reaches (nil for one with no
  ## declaration), that fn's name, the parameter it feeds ("" when unknown),
  ## and what the runtime does with it when the fn is the runtime's.

proc argTarget*(res: Resolution, m: Module, a: ArgOf): ArgTarget =
  ## Where the argument `a` goes (`a.call` is not nil).
  let callee = res.calleeOf(m, a.call)
  let name = if callee != nil: callee.name
             elif a.call.callee != nil and a.call.callee.kind == exkVar:
               a.call.callee.name
             else: ""
  let p = if callee != nil: paramFed(callee, a) else: a.name
  (callee, name, p, runtimeKeeps(name, p, a.index))

proc consumes*(res: Resolution, m: Module, d: Decl, pname: string,
               memo: var ConsumeMemo): bool

proc argConsumesWhy*(res: Resolution, m: Module, a: ArgOf,
                    memo: var ConsumeMemo): string =
  ## Why the parameter this argument feeds consumes it, or "" if it borrows.
  if a.call == nil: return "an unresolved call"   # `.name {args}` left as is
  let t = res.argTarget(m, a)
  case t.runtime
  of kKeeps: return "the runtime's " & t.name & " keeps it"
  of kBorrows: return ""
  of kUnknown: discard
  if t.callee == nil or t.callee.fnBody == nil or t.param.len == 0:
    return t.name & " has no body to ask"
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
      let s = pu.path[root.len + 1 .. ^1].split('.')[0]
      if s in w.slots[root]: keys.add slotKey(root, s)
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
  let s = path[root.len + 1 .. ^1].split('.')
  if s.len != 1 or s[0] notin w.slots[root]: return
  let k = slotKey(root, s[0])
  w.plan.overwrite[n.id] = w.st.getOrDefault(k, fOwned)
  w.st[k] = fOwned

proc walkAssign(w: var DropWalk, n: Expr) =
  ## The value is evaluated (and may move things), then the place is
  ## defined: a new owned place, or an owned place losing its old value.
  w.walkExpr(n.assignVal, uSink)
  let t = n.target
  if t == nil or w.res.isOwnerField(t): return
  if t.kind == exkField:
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
    var wild = false
    for arm in e.arms:
      bodies.add arm.body
      if arm.pattern != nil and arm.pattern.kind == pkWild: wild = true
    w.walkArms(bodies, use, not wild)
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
    if ownsHeap(m, p.typ) and res.consumes(m, d, p.name, w.memo):
      w.declare(p.name, p.typ)
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

proc placesOf*(res: Resolution, m: Module, d: Decl,
              memo: var ConsumeMemo): Places =
  ## Every parameter and every local a body binds; it owns the locals and
  ## its consuming parameters.
  for p in d.fnParams:
    result.all.incl p.name
    if ownsHeap(m, p.typ) and res.consumes(m, d, p.name, memo):
      result.owned.incl p.name
  for n in d.fnBody.nodes:
    if n.kind == exkAssign and n.target != nil and n.target.kind == exkVar and
       not res.isOwnerField(n.target):
      result.all.incl n.target.name
      result.owned.incl n.target.name

const ElementReads = ["at", "tuckAt", "tuckArrayAt"]
  ## The runtime's element reads: what they return is the container's own
  ## element, a view and not a fresh value.

proc readsElement*(res: Resolution, v: Expr): bool =
  ## `items[i]` or `{items, index} at`: an element read. Rule U: an element
  ## is never moved out of its container, so a sink of one copies it.
  let call = if v.kind == exkCall: v elif res.hasCall(v): res.call(v) else: nil
  v.kind == exkBracket or
    (call != nil and call.callee != nil and call.callee.kind == exkVar and
     call.callee.name in ElementReads)

proc copiesRead*(res: Resolution, ps: Places, v: Expr): bool =
  ## Rule S at one sink: does putting `v` there copy it? A read of a PLACE
  ## does unless it is the owned place's final use; so does an element read.
  ## Anything else is a temporary and moves: `Expr.Num {..}`, `State.Ready`
  ## or a nullary fn look like paths and are values built on the spot.
  if v != nil and res.readsElement(v): return true
  if v == nil or v.kind notin {exkVar, exkField} or pathOf(v).len == 0 or
     res.hasCall(v):
    return false                                   # a temporary moves
  if res.isOwnerField(v): return true              # an actor's field
  let root = rootOf(pathOf(v))
  if root notin ps.all: return false               # not a place at all
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
