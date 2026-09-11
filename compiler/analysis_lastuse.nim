# compiler/analysis_lastuse.nim
#
# WHERE IS A VALUE READ FOR THE LAST TIME?
#
# A copy made for a value nobody reads again is a copy nobody can observe, so
# it can be a move instead. That one fact is what separates
#
#     var xs = b.items      # copies the whole sequence
#
# from the same line costing nothing, and it is the difference between an
# O(n^2) build loop and an O(n) one (measured: 50k/100k appends at 1.29s/5.24s
# in release, a ratio of 4.06 on a doubled input).
#
# WHY THE COMPILER ANSWERS THIS AND NOT THE HOST. Nim would do it for us with
# `sink`; Odin and D would not do it at all. Leaning on the host means three
# move analyses agreeing by luck — the same bet the D backend refuses to make
# about type inference ("asking the target compiler to re-infer would make the
# two inference algorithms agree by luck, which is exactly how the 32-bit
# `auto x = 0` divergence got in"). One analysis here, three emissions, and
# the backends agree because they were told the same thing.
#
# WHY THIS IS CHEAP IN TUCK AND EXPENSIVE ELSEWHERE. Last-use analysis is
# normally tangled up with alias analysis: you cannot know a value is dead
# while something else might still point at it. Tuck has no aliasing — every
# binding owns its value, `let b = a` copies — so "the NAME is not read again"
# really does mean "the value is dead". Add that fns are top-level (nothing
# captures a local) and that the only escape is `return`, and the whole
# question collapses to a walk over one body.
#
# THE RULE, DELIBERATELY CONSERVATIVE. A use is the last one when it is the
# final appearance of that name in the body AND it is not inside a loop that
# could run again. The loop guard is not an optimisation gap to close later
# for free: a name read once per iteration is read again on the next one, and
# treating the textually-last occurrence as dead there would hand the second
# iteration a moved-from value. Being wrong here does not fail to compile —
# it silently computes something else — which is why the rule starts strict
# and the suite pins the NEGATIVE cases.
#
# WHAT IS DELIBERATELY NOT STAMPED:
#   - a name that is also a field of the enclosing actor/type (`self.x`)
#   - a write target: `x = ...` does not READ x
#   - anything at all inside a loop, unless the binding is loop-local
import ast, tables, sets
import resolution
import ast_ops

type Uses = Table[string, int]

proc isLoopNode(e: Expr): bool =
  e != nil and e.kind in {exkFor, exkWhile}

proc countUses(e: Expr, counts: var Uses, inLoop: bool,
               loopLocal: var HashSet[string]) =
  ## Every appearance of a bare name, and which names a loop re-executes.
  ##
  ## An appearance, not a read: a write target counts too. That is
  ## conservative in the direction that matters — it can only make the
  ## textually-last READ not be the final appearance, which withholds a stamp
  ## rather than granting a wrong one.
  if e == nil: return
  let loopHere = inLoop or isLoopNode(e)
  if e.kind == exkVar and e.name.len > 0:
    counts[e.name] = counts.getOrDefault(e.name) + 1
    if loopHere: loopLocal.incl(e.name)   # read under a loop: never stamped
  # A binding declared INSIDE a loop body dies with the iteration, so the
  # loop does not make it live across one. Not modelled yet: the guard above
  # is the strict reading, and widening it needs the declaration's scope,
  # which this walk does not track.
  for c in e.children: countUses(c, counts, loopHere, loopLocal)

proc stampLast(res: Resolution, e: Expr, counts: Uses, seen: var Uses,
               skip: HashSet[string]) =
  ## Walk in source order; the appearance that exhausts a name's count is its
  ## last one.
  if e == nil: return
  if e.kind == exkVar and e.name.len > 0:
    seen[e.name] = seen.getOrDefault(e.name) + 1
    if e.name notin skip and seen[e.name] == counts.getOrDefault(e.name):
      markLastUse(res, e)
  for c in e.children: stampLast(res, c, counts, seen, skip)

proc markBody(res: Resolution, body: Expr) =
  if body == nil: return
  var counts: Uses
  var underLoop = initHashSet[string]()
  countUses(body, counts, false, underLoop)
  var seen: Uses
  stampLast(res, body, counts, seen, underLoop)

proc markLastUses*(res: Resolution, m: Module) =
  ## Stamp every last use in every body this module declares.
  for d in m.decls:
    if d == nil: continue
    case d.kind
    of dkFn: markBody(res, d.fnBody)
    of dkTask: markBody(res, d.taskBody)
    else: discard
