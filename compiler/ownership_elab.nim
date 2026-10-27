# compiler/ownership_elab.nim
#
# THE ELABORATOR — Stage D of the ownership rules
# (thoughts/shared/plans/2026-10-05-ownership-rules-proposal.md, §2, §5).
#
# It computes, from the rules alone, which parameters consume (P), which
# sinks move and which copy (S), where each owned place is dropped (D) and
# reset (M), and what owning, dropping and copying a type means (G).
# `ownership_write` writes the answers into the tree; rule V checks them.
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
# cannot be read, so what it does is what its declaration says (`keeps`
# below): it reads everything unless it declares `[keeps: x]` or `[view: x]`.
import tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules
from ssa_ir import rootOf
from twin_shape import genericBaseBody

type ConsumeMemo* = object
  ## Rule P's answers so far, and the questions being answered (a recursive
  ## call into one reads as "borrows").
  known: Table[string, bool]
  busy: HashSet[string]

proc owning*(res: Resolution, m: Module, t: Type, strShared = false): bool
  ## Rule G (below): does a value of `t` own storage?

proc calleeOf*(res: Resolution, m: Module, call: Expr): Decl =
  ## The fn a call reaches: as the checker resolved it, else by name (calls
  ## that lowering built carry no resolution of their own), an imported
  ## extern included.
  result = res.declFor(call)
  if result == nil and call.callee != nil and call.callee.kind == exkVar:
    result = m.findFn(call.callee.name)
    if result == nil: result = res.externs.getOrDefault(call.callee.name)
    # A fn another module declares: found by name, unless two modules share it.
    if result == nil and call.callee.name notin res.ambiguousFns:
      result = res.fnBodies.getOrDefault(call.callee.name)
  elif result == nil and call.callee != nil and call.callee.kind == exkQualified and
       call.callee.modulePath.len > 0:
    # `mod::fn`: filed under its qualified name by recordQualifiedFns (A100).
    let q = call.callee.modulePath[^1] & "::" & call.callee.qualName
    result = res.fnBodies.getOrDefault(q)
    if result == nil: result = res.externs.getOrDefault(call.callee.qualName)
  if result != nil and result.kind notin {dkFn, dkTask}: result = nil

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

# A body-less callee (the runtime, an FFI extern, a `pending:` stub) cannot
# be read, so what it does with what it is given is what its DECLARATION
# says, and nothing else: it reads every argument and returns a fresh value
# (the C convention), unless it declares that it keeps one
# (`[keeps: value]`: the caller hands it over) or that its result is part of
# an argument (`[view: items]`: the caller copies it where it keeps it, and
# never drops it). Nothing is guessed from the types and no callee is named here.

proc keeps*(t: ArgTarget): bool =
  ## Does the body-less callee keep the argument it is given here?
  t.callee != nil and t.param.len > 0 and t.param in t.callee.externKeeps

proc consumes*(res: Resolution, m: Module, d: Decl, pname: string,
               memo: var ConsumeMemo): bool

proc argConsumesWhy*(res: Resolution, m: Module, a: ArgOf,
                    memo: var ConsumeMemo): string =
  ## Why the parameter this argument feeds consumes it, or "" if it borrows.
  if a.call == nil: return "an unresolved call"   # `.name {args}` left as is
  let t = res.argTarget(m, a)
  if t.bodyless:
    return if t.keeps: t.name & " has no body, and declares it keeps it" else: ""
  if res.consumes(m, t.callee, t.param, memo): t.name & " keeps it" else: ""

proc consumesWhy*(res: Resolution, m: Module, d: Decl, pname: string,
                  memo: var ConsumeMemo): string =
  ## Rule P with its reason: the first final read of `pname` that is a sink,
  ## named, or "" when `d` only borrows it. Not memoised; `consumes` is.
  if d.fnBody == nil: return ""
  for pu in res.placeUsesOf(d.fnBody):
    if rootOf(pu.path) != pname or not res.isLastUse(pu.read): continue
    if not res.owning(m, res.typeFor(pu.read)): continue   # carries nothing
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
      ## the owned places that are a `str` (the shadow compares them apart)
    partMoves*: seq[Expr]
      ## reads that move a part out of a slot that stays owned: each part is
      ## emptied right after it moves (rule M)
    slotTypes*: Table[string, Type]
      ## slot key -> the type of what it holds: what dropping it means (G)
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

# --- RULE G: what owning, dropping and copying a value of a type means -----
#
# A value OWNS storage unless its type provably owns none: a scalar, or a
# declared type made only of such. A `Seq` or a `str` owns its buffer; a
# record, a sum, a tuple or a `?T`/`!T` owns what its parts own; and a type
# the compiler cannot see through (a generic parameter, one it cannot
# resolve) is taken to own, so its copies and drops are written and the
# runtime's walk does nothing for one that owns nothing.
#
# Dropping or copying one is a single buffer for a Seq of plain values
# (`delete`, `tuckSeqCopy`) and a clone for a `str` (cpStatic); anything
# else is walked whole (cpDeep, `dropDeep`: the Odin runtime's `tuckCopy`
# and `tuckDrop`, read off the type at the point of use).

const PlainNames = ["int", "i8", "i16", "i32", "i64", "u8", "u16", "u32",
                    "u64", "usize", "f32", "f64", "float", "bool", "char",
                    "void", "unit"]

proc ownsNothing(res: Resolution, m: Module, t: Type, depth = 0,
                 strShared = false): bool

proc allOwnNothing(res: Resolution, m: Module, ts: seq[Type], depth: int,
                   strShared: bool): bool =
  for t in ts:
    if not res.ownsNothing(m, t, depth, strShared): return false
  true

proc fieldsOwnNothing(res: Resolution, m: Module, fs: seq[FieldDef],
                      depth: int, strShared: bool): bool =
  for f in fs:
    if not res.ownsNothing(m, f.typ, depth, strShared): return false
  true

proc bodyOwnsNothing(res: Resolution, m: Module, d: Decl, depth: int,
                     strShared: bool): bool =
  ## A declared type's body: its fields, its variants' payloads, its alias;
  ## or a registry's events.
  if d != nil and d.kind == dkRegistry:
    for v in d.variants:
      if not res.fieldsOwnNothing(m, v.fields, depth, strShared): return false
    return true
  if d != nil and d.kind == dkObject:
    return res.fieldsOwnNothing(m, d.objFields, depth, strShared)
  if d == nil or d.kind != dkType or d.typeBody == nil: return false
  let b = d.typeBody
  case b.kind
  of tkRecord: res.fieldsOwnNothing(m, b.fields, depth, strShared)
  of tkSum:
    for v in b.variants:
      if not res.fieldsOwnNothing(m, v.fields, depth, strShared): return false
    true
  of tkNamed, tkApp, tkTuple, tkFunc, tkUnion, tkEffect, tkRename:
    res.ownsNothing(m, b, depth, strShared)

proc isHandle(res: Resolution, name: string): bool =
  ## A reference a slab, an arena or a pool hands out, or a resource's
  ## handle: an index into storage someone else owns, never storage itself.
  for s in res.slabNames.keys:
    if slabRefName(s) == name: return true
  for a in res.arenaNames.keys:
    if arenaRefName(a) == name: return true
  for p in res.poolNames.keys:
    if poolHandleName(p) == name: return true
  name.endsWith("Handle")      # resourceHandleName: `udp` hands out UdpHandle

proc namedOwnsNothing(res: Resolution, m: Module, t: Type, depth: int,
                      strShared: bool): bool =
  ## A type named bare: a scalar, `str`, a declared type, a registry or a
  ## handle.
  if t.name in PlainNames: return true
  if t.name == "str": return strShared
  var d = res.declForType(t)
  if d == nil: d = m.findDecl(dkType, t.name)
  if d == nil: d = res.registryNames.getOrDefault(t.name)
  if d == nil: return res.isHandle(t.name)
  if d.kind == dkType and d.generics.len > 0: return false
  res.bodyOwnsNothing(m, d, depth + 1, strShared)

proc appOwnsNothing(res: Resolution, m: Module, t: Type, depth: int,
                    strShared: bool): bool =
  ## A type applied to arguments: a Seq owns; `?T`, `!T` and `Array[T, N]`
  ## own what their arguments do; a declared generic, what its body does.
  if seqElem(t) != nil: return false
  let base = if t.base != nil and t.base.kind == tkNamed: t.base.name else: ""
  if base in ["!", "?", "!?", "Array"]:
    return res.allOwnNothing(m, t.args, depth + 1, strShared)
  var d = if t.base != nil: res.declForType(t.base) else: nil
  if d == nil and base.len > 0: d = m.findDecl(dkType, base)
  if d == nil and res.isHandle(base): return true   # `FrameRef[Header]`
  res.allOwnNothing(m, t.args, depth + 1, strShared) and
    res.bodyOwnsNothing(m, d, depth + 1, strShared)

proc ownsNothing(res: Resolution, m: Module, t: Type, depth = 0,
                 strShared = false): bool =
  ## Does a value of `t` provably own no storage? `strShared`: a `str` is
  ## immutable and shared by every copy (D), so it owns nothing a copy needs.
  if t == nil or depth > 8: return false
  case t.kind
  of tkNamed: res.namedOwnsNothing(m, t, depth, strShared)
  of tkApp: res.appOwnsNothing(m, t, depth, strShared)
  of tkRecord: res.fieldsOwnNothing(m, t.fields, depth + 1, strShared)
  of tkSum:
    for v in t.variants:
      if not res.fieldsOwnNothing(m, v.fields, depth + 1, strShared): return false
    true
  of tkTuple: res.allOwnNothing(m, t.elems, depth + 1, strShared)
  of tkFunc, tkEffect: true
  of tkUnion, tkRename: false

proc owning*(res: Resolution, m: Module, t: Type, strShared = false): bool =
  ## Rule G: does a value of `t` own storage (or might it)? Nil (no type
  ## known) owns nothing the rules can name.
  t != nil and not res.ownsNothing(m, t, strShared = strShared)

proc copyKindOf*(res: Resolution, m: Module, t: Type,
                  strShared = false): CopyKind =
  ## How a copy of an owning value of `t` is made.
  if isStr(t): cpStatic
  elif seqElem(t) != nil and
       res.ownsNothing(m, seqElem(t), strShared = strShared): cpSeq
  else: cpDeep

proc dropsDeep*(res: Resolution, m: Module, t: Type): bool =
  ## Is dropping a value of `t` more than freeing one buffer of plain values?
  res.copyKindOf(m, t) != cpSeq

proc recordBody(res: Resolution, m: Module, t: Type): Type =
  ## The record a type is, or nil: inline, declared, or a generic one's
  ## declared body.
  var b = t
  if b.kind == tkApp: b = genericBaseBody(m, b)
  if b != nil and b.kind == tkNamed:
    var d = res.declForType(b)
    if d == nil: d = m.findDecl(dkType, b.name)
    b = if d != nil and d.kind == dkType: d.typeBody else: nil
  if b != nil and b.kind == tkRecord: b else: nil

proc slotTypes*(res: Resolution, m: Module, t: Type): seq[(string, Type)] =
  ## What a value of type `t` owns, slot by slot, each with its type: a
  ## record's owning fields by name, or "" (the value itself) for anything
  ## else that owns.
  if not res.owning(m, t): return
  let rec = res.recordBody(m, t)
  if rec == nil: return @[("", t)]
  for f in rec.fields:
    if res.owning(m, f.typ): result.add (f.name, f.typ)

proc slotsOf*(res: Resolution, m: Module, t: Type): seq[string] =
  ## The slot names of `slotTypes`.
  for (s, _) in res.slotTypes(m, t): result.add s

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
    if not w.res.owning(w.m, w.res.typeFor(pu.read)) or not w.sinksAway(pu):
      continue
    var keys: seq[string]
    if pu.path == root:
      for s in w.slots[root]: keys.add slotKey(root, s)
    else:
      let segs = pu.path[root.len + 1 .. ^1].split('.')
      if segs.len == 1 and segs[0] in w.slots[root]:
        keys.add slotKey(root, segs[0])
      elif segs[0] in w.slots[root] or "" in w.slots[root]:
        # A PART of what a slot holds (`r.value` of a `?str`, `b.inner.xs`):
        # the slot stays owned, and the part is emptied where it moves, so
        # the slot's drop frees the rest and not the part (rule M).
        w.plan.partMoves.add pu.read
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
  let ss = w.res.slotTypes(w.m, t)
  if ss.len == 0: return
  w.slots[place] = @[]
  w.scopes[^1].add place
  if isStr(t): w.plan.strs.incl place
  for (s, st) in ss:
    w.slots[place].add s
    w.st[slotKey(place, s)] = fOwned
    w.plan.slotTypes[slotKey(place, s)] = st

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

# --- sibling-scope locals ---------------------------------------------------
#
# The plan below is keyed by a place's NAME, so two locals that share one in
# sibling scopes (`let h` in an `if`, `let h` again in a loop) would share a
# fate and a list of moves: the second `h` was pushed AND dropped (#142). A
# name that is declared a second time in a function is renamed from there to
# the end of its scope, before the plan reads anything.

type Uniquify = object
  res: Resolution
  visible: seq[HashSet[string]]       ## the names in scope, innermost last
  sites: Table[string, NodeId]        ## every name declared so far -> where
  fresh: int

proc isVisible(u: Uniquify, name: string): bool =
  for sc in u.visible:
    if name in sc: return true

proc renameIn(res: Resolution, e: Expr, old, fresh: string) =
  ## Every `old` under `e` becomes `fresh`, including inside a call the
  ## checker printed in a node's place (`x.len` is one, kept off the tree).
  for n in e.nodes:
    if n.kind == exkVar and n.name == old: n.name = fresh
    if n.kind != exkCall and res.hasCall(n): res.renameIn(res.call(n), old, fresh)

proc renameFrom(res: Resolution, b: Expr, i: int, old, fresh: string) =
  ## `old` is `fresh` from statement `i` of `b` to the end of the block.
  for j in i ..< b.stmts.len: res.renameIn(b.stmts[j], old, fresh)

proc uniquify(u: var Uniquify, e: Expr)

proc uniquifyDecl(u: var Uniquify, b: Expr, i: int) =
  ## A statement that declares a name already declared elsewhere gets a new one.
  let s = b.stmts[i]
  let t = s.target
  if t == nil or t.kind != exkVar or u.res.isOwnerField(t): return
  # A `let`/`var` of a name already in scope, an enclosing one's (A81) or
  # this block's own (A90), is a new local until this block ends; without a
  # name of its own it would store into the old one, whatever its type. Only
  # a plain `x = ...` of a visible name is a reassignment.
  let shadows = s.isDecl and u.isVisible(t.name)
  if u.isVisible(t.name) and not shadows: return
  if shadows or (t.name in u.sites and u.sites[t.name] != s.id):
    inc u.fresh
    let old = t.name
    let fresh = old & "ˑ" & $u.fresh
    # The declaration's own value still reads the old one: `let x = x + 1`.
    t.name = fresh
    u.res.renameFrom(b, i + 1, old, fresh)
  u.sites[t.name] = s.id
  u.visible[^1].incl t.name

proc uniquify(u: var Uniquify, e: Expr) =
  if e == nil: return
  case e.kind
  of exkBlock:
    u.visible.add initHashSet[string]()
    for i, s in e.stmts:
      u.uniquify(s)
      if s.kind == exkAssign: u.uniquifyDecl(e, i)
    discard u.visible.pop()
  of exkFor:
    u.uniquify(e.iterable)
    u.visible.add initHashSet[string]()
    var names: seq[string]
    var pats = @[e.iter]
    while pats.len > 0:
      let p = pats.pop()
      if p == nil: continue
      if p.kind == pkVar: names.add p.name
      elif p.kind == pkTuple: pats.add p.elems
    for n in names: u.visible[^1].incl n
    u.uniquify(e.body)
    discard u.visible.pop()
  else:
    for c in e.children: u.uniquify(c)

proc dropPlan*(res: Resolution, m: Module, d: Decl): DropPlan =
  ## Rules D and M for one fn: its owned locals, and its consuming
  ## parameters (P), each with its fate where its scope ends.
  if d.fnBody == nil: return
  var u = Uniquify(res: res)
  u.visible.add initHashSet[string]()
  for p in d.fnParams: u.visible[0].incl p.name
  u.uniquify(d.fnBody)
  var w = DropWalk(res: res, m: m)
  w.scopes.add @[]
  for p in d.fnParams:
    if res.owning(m, p.typ) and res.consumes(m, d, p.name, w.memo):
      w.declare(p.name, p.typ)
  w.walkExpr(d.fnBody, uSink)
  if not w.dead:
    for place in w.scopes[0]: w.endScopeOf(place)
  w.plan

# --- RULE S: which sinks copy ------------------------------------------------
#
# A sink moves at the final use of an owned place, and copies otherwise
# (`ownership_write` puts the copies in). At a binding `x = v` that means: `v` a read of a place this body owns (a
# local, or a consuming parameter) moves when the read is final and copies
# when it is not; a read of anything it does not own (a borrowing parameter,
# an actor's field) always copies; a temporary (a call's result, a literal)
# is the binding's already and never copies. A construction's fields are
# sinks of their own, so `{items: xs} Bag` copies `items` exactly when `xs`
# would be copied bound alone. (A call's result needs no provenance
# question: if the callee returned a parameter it only borrowed, rule S
# copied it inside the callee.)

type Places* = object
  ## A body's places: every parameter and local, and the ones it owns.
  all, owned: HashSet[string]
  m: Module

proc patternNames(p: Pattern, names: var seq[string]) =
  ## The names a pattern binds (a bare name may also be a variant to test:
  ## it is then never read as a variable, so listing it is harmless).
  if p == nil: return
  case p.kind
  of pkVar, pkBind: names.add p.name
  of pkRecord:
    for (_, sub) in p.fields: patternNames(sub, names)
  of pkTuple:
    for sub in p.elems: patternNames(sub, names)
  of pkOr:
    patternNames(p.left, names)
    patternNames(p.right, names)
  of pkTypeTest: names.add p.bindAs
  of pkWild, pkLit: discard

proc placesOf*(res: Resolution, m: Module, d: Decl,
              memo: var ConsumeMemo): Places =
  ## Every parameter and every local a body binds; it owns the locals and
  ## its consuming parameters.
  result.m = m
  for p in d.fnParams:
    result.all.incl p.name
    if res.owning(m, p.typ) and res.consumes(m, d, p.name, memo):
      result.owned.incl p.name
  for n in d.fnBody.nodes:
    if n.kind == exkAssign and n.target != nil and n.target.kind == exkVar and
       not res.isOwnerField(n.target):
      result.all.incl n.target.name
      result.owned.incl n.target.name
  # What a `for` or a `match` binds is a VIEW of what it walks: a place, but
  # not the body's own, so a sink of it copies and nothing drops it.
  var bound: seq[string]
  for n in d.fnBody.nodes:
    case n.kind
    of exkFor: patternNames(n.iter, bound)
    of exkMatch:
      for arm in n.arms: patternNames(arm.pattern, bound)
    else: discard
  for name in bound:
    if name notin result.owned: result.all.incl name

proc owns*(ps: Places, place: string): bool =
  ## Does the body own this place (a local, or a consuming parameter)?
  place in ps.owned

proc readsElement*(res: Resolution, m: Module, v: Expr): bool =
  ## A read of something another value holds, not a fresh value: `items[i]`
  ## (rule U: an element is never moved out of its container), a slab's cell
  ## (`Lists.get {r: l}`: the slab keeps it), or a call
  ## to a body-less callee that declares its result a `[view: x]`. A sink of
  ## one copies it.
  if v.kind in {exkBracket, exkSlabCell}: return true   # a slab's cell too
  if v.kind == exkSlabOp and v.slabOp == soGet: return true
  if v.kind == exkField and not res.hasCall(v) and v.receiver != nil:
    return res.readsElement(m, v.receiver)  # `items[i].key`: part of one
  let call = if v.kind == exkCall: v elif res.hasCall(v): res.call(v) else: nil
  if call == nil or call.kind != exkCall: return false
  let d = res.calleeOf(m, call)
  d != nil and d.fnBody == nil and d.externView.len > 0 and
    res.owning(m, res.typeFor(v))

proc copiesRead*(res: Resolution, ps: Places, v: Expr): bool =
  ## Rule S at one sink: does putting `v` there copy it? A read of a PLACE
  ## does unless it is the owned place's final use; so does an element read.
  ## Anything else is a temporary and moves: `Expr.Num {..}`, `State.Ready`
  ## or a nullary fn look like paths and are values built on the spot.
  if v != nil and res.readsElement(ps.m, v): return true
  if v == nil or v.kind notin {exkVar, exkField} or pathOf(v).len == 0 or
     res.hasCall(v):
    return false                                   # a temporary moves
  if res.isOwnerField(v): return true              # an actor's field
  let root = rootOf(pathOf(v))
  if root notin ps.all:
    # A module const is read in place and owned by nobody: a local made from
    # it holds a copy (#146).
    return ps.m.findDecl(dkConst, root) != nil
  root notin ps.owned or not res.isLastUse(v)
