# tests/escape_solver.nim
#
# The escape solver (compiler/escape.nim), tested on its own.
#
# A Nim test rather than a shell one, deliberately: every other test here
# drives the ./tuck binary because it is checking the COMPILER's behaviour.
# This module has no compiler dependencies at all — it is a lattice solver over
# opaque integers — so the honest test calls it directly. That also lets it be
# hammered with random graphs, which no .tuck source could express.
#
# The stakes are asymmetric and the tests are written around that: a wrong
# "escapes" costs a promotion nobody needed, a wrong "does not escape" is a
# dangling pointer. So the conservative direction is tested hardest.
import ../compiler/escape
import random, sets, tables

var failures = 0

proc check(name: string, cond: bool) =
  if cond: echo "PASS  ", name
  else:
    echo "FAIL  ", name
    failures.inc

# --- the default is escaping -----------------------------------------------

block:
  let g = initEscapeGraph()
  check "an unknown id escapes", g.escapes(1)
  check "an unknown id is esGlobal", g.stateOf(1) == esGlobal
  check "an unknown id may not stay on the stack", not g.mayStayOnStack(1)

# --- direct observations ----------------------------------------------------

block:
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.solve()
  check "a local noted as not escaping does not", not g.escapes(1)

block:
  var g = initEscapeGraph()
  g.note(1, esGlobal)
  g.solve()
  check "a local noted as global escapes", g.escapes(1)

block:
  var g = initEscapeGraph()
  g.note(1, esArg)
  g.solve()
  check "esArg counts as escaping in a leaf analysis", g.escapes(1)
  check "...but is distinguishable for the caller", g.stateOf(1) == esArg

# --- states rise, never fall ------------------------------------------------

block:
  var g = initEscapeGraph()
  g.note(1, esGlobal)
  g.note(1, esNone)     # an earlier truth does not un-escape it
  g.solve()
  check "noting esNone does not lower an escaped id", g.escapes(1)

block:
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.note(1, esGlobal)
  g.solve()
  check "noting esGlobal raises a clean id", g.escapes(1)

# --- flow propagates backwards ----------------------------------------------

block:
  # d -> wrapped -> returned
  var g = initEscapeGraph()
  g.note(1, esNone)      # the local
  g.note(2, esNone)      # the interface value made from it
  g.note(3, esGlobal)    # the return slot
  g.flow(1, 2)
  g.flow(2, 3)
  g.solve()
  check "escape propagates back along a chain", g.escapes(1)
  check "and the middle escapes too", g.escapes(2)

block:
  # the same chain, but nothing at the end escapes
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.note(2, esNone)
  g.note(3, esNone)
  g.flow(1, 2)
  g.flow(2, 3)
  g.solve()
  check "a chain that reaches nothing escaping stays on the stack",
        not g.escapes(1)

block:
  # one branch escapes, the other does not — the max wins
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.note(2, esNone)
  g.note(3, esGlobal)
  g.flow(1, 2)
  g.flow(1, 3)
  g.solve()
  check "a value reaching ANY escaping use escapes", g.escapes(1)
  check "the branch that does not escape is unaffected", not g.escapes(2)

# --- cycles terminate -------------------------------------------------------

block:
  # x = f(x) — a self-referential flow must not spin
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.note(2, esNone)
  g.flow(1, 2)
  g.flow(2, 1)
  g.solve()
  check "a 2-cycle terminates and stays clean", not g.escapes(1)

block:
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.note(2, esNone)
  g.note(3, esGlobal)
  g.flow(1, 2)
  g.flow(2, 1)     # cycle
  g.flow(2, 3)     # ...with an escaping exit
  g.solve()
  check "a cycle with an escaping exit escapes throughout", g.escapes(1)
  check "both members of the cycle escape", g.escapes(2)

block:
  # self-flow is dropped rather than looping
  var g = initEscapeGraph()
  g.note(1, esNone)
  g.flow(1, 1)
  g.solve()
  check "self-flow terminates", not g.escapes(1)

# --- order independence -----------------------------------------------------

block:
  # the same facts in the opposite order must give the same answer
  var a = initEscapeGraph()
  a.note(1, esNone); a.note(2, esNone); a.note(3, esGlobal)
  a.flow(1, 2); a.flow(2, 3)
  a.solve()

  var b = initEscapeGraph()
  b.flow(2, 3); b.flow(1, 2)
  b.note(3, esGlobal); b.note(2, esNone); b.note(1, esNone)
  b.solve()

  check "the answer does not depend on fact order",
        a.escapes(1) == b.escapes(1) and a.escapes(2) == b.escapes(2)

# --- a long chain -----------------------------------------------------------

block:
  # 1 -> 2 -> ... -> 500 -> escaping. Every link must escape.
  var g = initEscapeGraph()
  for i in 1 .. 500: g.note(i, esNone)
  g.note(501, esGlobal)
  for i in 1 .. 500: g.flow(i, i + 1)
  g.solve()
  var allEscaped = true
  for i in 1 .. 501:
    if not g.escapes(i): allEscaped = false
  check "a 500-link chain propagates end to end", allEscaped

block:
  # the same chain with a clean end — none may escape
  var g = initEscapeGraph()
  for i in 1 .. 501: g.note(i, esNone)
  for i in 1 .. 500: g.flow(i, i + 1)
  g.solve()
  var noneEscaped = true
  for i in 1 .. 501:
    if g.escapes(i): noneEscaped = false
  check "a 500-link clean chain stays clean", noneEscaped

# --- randomised: the property that must never break ------------------------

block:
  # THE INVARIANT: if a flows (transitively) to something escaping, a escapes.
  # Checked against a brute-force reachability walk on random graphs — the
  # solver and the checker must agree, and disagreeing in the unsafe direction
  # is the failure that matters.
  var rng = initRand(20260802)
  var mismatches = 0
  var unsafeMismatches = 0
  for trial in 1 .. 400:
    let n = rng.rand(2 .. 25)
    var g = initEscapeGraph()
    var escapingSeeds = initHashSet[int]()
    for i in 1 .. n:
      if rng.rand(1.0) < 0.15:
        g.note(i, esGlobal)
        escapingSeeds.incl(i)
      else:
        g.note(i, esNone)
    var adj = initTable[int, seq[int]]()
    for i in 1 .. n:
      for _ in 0 .. rng.rand(0 .. 2):
        let dst = rng.rand(1 .. n)
        if dst != i:
          g.flow(i, dst)
          adj.mgetOrPut(i, @[]).add(dst)
    g.solve()

    # brute force: can i reach any seed?
    for i in 1 .. n:
      var seen = initHashSet[int]()
      var stack = @[i]
      var reaches = i in escapingSeeds
      while stack.len > 0:
        let cur = stack.pop()
        if cur in seen: continue
        seen.incl(cur)
        if cur in escapingSeeds: reaches = true
        for nxt in adj.getOrDefault(cur, @[]): stack.add(nxt)
      if g.escapes(i) != reaches:
        mismatches.inc
        # the dangerous direction: solver says safe, reality says it escapes
        if reaches and not g.escapes(i): unsafeMismatches.inc

  check "randomised: solver matches brute-force reachability", mismatches == 0
  check "randomised: NEVER unsafe (no false 'does not escape')",
        unsafeMismatches == 0

# --- densely connected ------------------------------------------------------

block:
  # every id flows to every other; one escapes, so all must
  var g = initEscapeGraph()
  const n = 40
  for i in 1 .. n: g.note(i, esNone)
  g.note(n, esGlobal)
  for i in 1 .. n:
    for j in 1 .. n:
      if i != j: g.flow(i, j)
  g.solve()
  var allEscaped = true
  for i in 1 .. n:
    if not g.escapes(i): allEscaped = false
  check "a fully connected graph propagates to all", allEscaped

if failures > 0:
  echo failures, " escape solver test(s) failed"
  quit(1)
echo "All escape solver tests passed"
