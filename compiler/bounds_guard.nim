# compiler/bounds_guard.nim
#
# A BOUNDS CHECK A LOOP CAN ANSWER ONCE (third benchmark pass).
#
#   for i in 0 ..< n:
#     s = s + xs[i] * ys[i + 1]
#
# Every `xs[i]` checks `0 <= i < xs.len`, and the check reloads `xs.len`
# because a store into the array may alias it. Measured with the checks
# compiled out (Nim, clang): permute 2.1x, matmul 2.4x, heapsort 1.7x, life 2x,
# levenshtein 1.5x, qsort 1.4x. The loop knows its whole range up front, so
# when `xs` keeps its length through the loop and every index is the loop
# variable plus something that does not change, the whole range can be proved
# in range BEFORE the loop:
#
#   lo + inv + cmin >= 0   and   hi + inv + cmax <= xs.len
#
# and the loop is then printed twice: an unchecked copy under that guard, and
# the original, checked, under its negation. Behaviour is exactly the same
# program on both paths (a violation still fails at the access that breaks,
# after the earlier iterations' effects), so nothing is lost but the checks.
#
# WHAT QUALIFIES, all of it read off the tree:
#   - a `for` over `lo ..< hi` / `lo .. hi` whose bounds are names, numbers
#     and their arithmetic (`n`, `xs.len`, `n - 1`), with a plain loop name;
#   - an access `xs[e]` (read or write) where `xs` is a local name of a Seq of
#     values that own nothing (ints, floats, bools, bytes), and `e` is the loop
#     name, plus or minus a number, plus an expression `inv` over names the
#     loop never assigns (`i * n + j` over `j`, with `i * n` as `inv`);
#   - `xs` is not assigned, appended to, or handed to a parameter that keeps it
#     anywhere in the loop (an element write is fine: the length is the same).
# Anything else keeps its check.
#
# The decision is recorded in two tables keyed by node id (as twin_calls does),
# and the emitters print it: `loopGuards(loop)` for the guard and the pair of
# loops, `vouchingLoop(access)` for an access that may skip its check while
# that loop's unchecked copy is the one being printed.
import tables, sets, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_rules, ownership_elab
import parser_stringify
from ssa_ir import rootOf

type Guard* = object
  recv*: Expr      ## the Seq (a bare local name)
  inv*: Expr       ## the loop-invariant part of the index, or nil
  lo*, hi*: int    ## the least and greatest constant added to the loop name

var guardsByLoop: Table[NodeId, seq[Guard]]
var loopOfAccess: Table[NodeId, NodeId]

proc loopGuards*(loop: Expr): seq[Guard] =
  ## The guards that let `loop` print an unchecked copy; empty: it does not.
  guardsByLoop.getOrDefault(loop.id)

proc vouchingLoop*(access: Expr): NodeId =
  ## The loop whose guard covers this access, or 0.
  loopOfAccess.getOrDefault(access.id, NodeId(0))

# --- what an index and a bound may be ------------------------------------------

proc isIntLit(e: Expr): bool = e != nil and e.kind == exkLit and e.litKind == lkInt

proc litValue(e: Expr): int = parseInt(e.litValue)

proc simpleBound(res: Resolution, e: Expr): bool =
  ## Names, numbers, arithmetic and `.len`: evaluating it twice changes nothing.
  if e == nil: return false
  case e.kind
  of exkLit: e.litKind == lkInt
  of exkVar: true
  of exkField:
    if res.hasCall(e):
      let c = res.call(e)
      c != nil and c.kind == exkCall and c.callee != nil and
        c.callee.kind == exkVar and c.callee.name in ["len", "count"] and
        c.args.len == 1 and c.args[0] != nil and c.args[0].kind == exkVar
    else: false
  of exkBinary:
    e.binOp in {boAdd, boSub, boMul} and res.simpleBound(e.left) and
      res.simpleBound(e.right)
  else: false

proc patternNames(p: Pattern, acc: var HashSet[string]) =
  if p == nil: return
  case p.kind
  of pkVar: acc.incl p.name
  of pkTuple:
    for el in p.elems: patternNames(el, acc)
  else: discard

proc unavailableBefore(body: Expr): HashSet[string] =
  ## Names a part of the index must not use: those the loop writes whole,
  ## appends to, or declares (a `let`, a nested loop's name) — the last do not
  ## exist before the loop, where the guard is evaluated.
  for n in body.nodes:
    case n.kind
    of exkAssign:
      if n.target != nil: result.incl rootOf(pathOf(n.target))
    of exkAppend:
      if n.appendTarget != nil: result.incl rootOf(pathOf(n.appendTarget))
    of exkFor: patternNames(n.iter, result)
    else: discard

proc invariant(res: Resolution, e: Expr, loopVar: string,
               assigned: HashSet[string]): bool =
  ## An index part that is the same on every iteration.
  if e == nil: return false
  case e.kind
  of exkLit: e.litKind == lkInt
  of exkVar: e.name != loopVar and e.name notin assigned
  of exkBinary:
    e.binOp in {boAdd, boSub, boMul} and
      res.invariant(e.left, loopVar, assigned) and
      res.invariant(e.right, loopVar, assigned)
  else: false

type Affine = tuple[ok: bool, inv: Expr, c: int]

proc plusLit(a: Affine, e: Expr, op: BinOp): Affine =
  ## `a` with the literal `e` added or taken away.
  let k = litValue(e)
  (true, a.inv, if op == boAdd: a.c + k else: a.c - k)

proc affine(res: Resolution, e: Expr, loopVar: string,
            assigned: HashSet[string]): Affine

proc leftAffine(res: Resolution, e: Expr, loopVar: string,
                assigned: HashSet[string]): Affine =
  ## `loopVar + c (+ inv)` as the LEFT operand of `e`, the rest a number or an
  ## expression the loop leaves alone.
  let l = res.affine(e.left, loopVar, assigned)
  if not l.ok: return
  if isIntLit(e.right): return l.plusLit(e.right, e.binOp)
  if e.binOp == boAdd and l.inv == nil and
     res.invariant(e.right, loopVar, assigned):
    return (true, e.right, l.c)

proc rightAffine(res: Resolution, e: Expr, loopVar: string,
                 assigned: HashSet[string]): Affine =
  ## The same with the loop's part on the right: `n * i0 + j`.
  let r = res.affine(e.right, loopVar, assigned)
  if not r.ok: return
  if isIntLit(e.left): return r.plusLit(e.left, boAdd)
  if r.inv == nil and res.invariant(e.left, loopVar, assigned):
    return (true, e.left, r.c)

proc affine(res: Resolution, e: Expr, loopVar: string,
            assigned: HashSet[string]): Affine =
  ## `e` as loopVar + c (+ inv), or not ok.
  if e == nil: return
  if e.kind == exkVar and e.name == loopVar: return (true, nil, 0)
  if e.kind != exkBinary or e.binOp notin {boAdd, boSub}: return
  result = res.leftAffine(e, loopVar, assigned)
  if not result.ok and e.binOp == boAdd:
    result = res.rightAffine(e, loopVar, assigned)

# --- which Seqs keep their length through the loop -----------------------------

proc keepsLength(res: Resolution, m: Module, memo: var ConsumeMemo,
                 body: Expr, name: string): bool =
  for n in body.nodes:
    case n.kind
    of exkAssign:
      if n.target != nil and rootOf(pathOf(n.target)) == name: return false
    of exkAppend:
      if n.appendTarget != nil and rootOf(pathOf(n.appendTarget)) == name:
        return false
    else: discard
  for pu in res.placeUsesUnder(body, uNone):
    if rootOf(pu.path) != name: continue
    case pu.use
    of uSink, uMutBorrow, uDrop: return false
    of uArg:
      if res.argConsumesWhy(m, pu.arg, memo).len > 0: return false
    else: discard
  true

# --- one loop ---------------------------------------------------------------------

type Candidate = object
  recv: Expr
  inv: Expr
  lo, hi: int
  accesses: seq[NodeId]

proc qualifies(res: Resolution, m: Module, bracket: Expr): bool =
  ## A single-index read or write of a Seq local whose elements own nothing.
  if bracket.brArgs.len != 1: return false
  let r = bracket.brReceiver
  if r == nil or r.kind != exkVar or res.isOwnerField(r): return false
  let elem = seqElem(res.typeFor(r))
  elem != nil and not res.owning(m, elem)

proc consider(cands: var seq[Candidate], recv, inv: Expr, c: int, ids: seq[NodeId]) =
  let key = if inv == nil: "" else: inv.toString
  for k in cands.mitems:
    let same = k.recv.name == recv.name and
      (if k.inv == nil: "" else: k.inv.toString) == key
    if same:
      k.lo = min(k.lo, c)
      k.hi = max(k.hi, c)
      k.accesses.add ids
      return
  cands.add Candidate(recv: recv, inv: inv, lo: c, hi: c, accesses: ids)

proc rangeLoopVar(loop: Expr): string =
  ## The name of a `for` over a plain range, or "".
  let it = loop.iterable
  if it == nil or it.kind != exkBinary or
     it.binOp notin {boRangeExcl, boRangeIncl}: return ""
  if loop.iter == nil or loop.iter.kind != pkVar: return ""
  loop.iter.name

proc collect(res: Resolution, m: Module, loop: Expr, v: string,
             assigned: HashSet[string]): seq[Candidate] =
  ## Every access in the loop's body that is `v + c (+ inv)` into a Seq local.
  var assignOf: Table[NodeId, NodeId]   # bracket id -> its assignment's id
  for n in loop.body.nodes:
    if n.kind == exkBracketAssign and n.brTarget != nil:
      assignOf[n.brTarget.id] = n.id
  for n in loop.body.nodes:
    if n.kind != exkBracket or not res.qualifies(m, n): continue
    let a = res.affine(n.brArgs[0], v, assigned)
    if not a.ok: continue
    var ids = @[n.id]
    if n.id in assignOf: ids.add assignOf[n.id]
    result.consider(n.brReceiver, a.inv, a.c, ids)

proc guardLoop(res: Resolution, m: Module, memo: var ConsumeMemo, loop: Expr) =
  let v = rangeLoopVar(loop)
  if v == "": return
  let it = loop.iterable
  if not res.simpleBound(it.left) or not res.simpleBound(it.right): return
  let assigned = unavailableBefore(loop.body)
  if v in assigned: return          # a nested name shadows the loop's
  var guards: seq[Guard]
  for c in res.collect(m, loop, v, assigned):
    if not res.keepsLength(m, memo, loop.body, c.recv.name): continue
    guards.add Guard(recv: c.recv, inv: c.inv, lo: c.lo, hi: c.hi)
    for id in c.accesses: loopOfAccess[id] = loop.id
  if guards.len > 0: guardsByLoop[loop.id] = guards

proc markBoundsGuards*(res: Resolution, m: Module) =
  ## Run after the appends are made and before the ownership writes: the loops
  ## whose accesses can be checked once.
  var memo: ConsumeMemo
  for body in m.bodies:
    for n in body.nodes:
      if n.kind == exkFor: res.guardLoop(m, memo, n)
