# compiler/typecheck_transitions.nim
#
# Transition-table validation (spec 4.4), split out of typecheck.nim.
#
# Two rules, both about a sum type's declared `from -> to` edges:
#   1. every endpoint names a real variant of the type
#   2. a [sealed] type's variants are ALL reachable from the initial (first)
#      variant — a state nothing can reach is a state you wrote by mistake
#
# Why this one lifts out cleanly when most of the checker does not: it is a
# question about ONE declaration's own type body. It never synthesizes an
# expression type, so it never needs the TypeChecker — it took a `tc`
# parameter in typecheck.nim purely to match its sibling checkers' shape and
# never read it. The parameter is dropped here rather than carried along dead.
#
# checkDecisionTable, its neighbour in typecheck.nim, does NOT move: it calls
# tc.synthesize on every row body and reads tc.module for enum domains. That
# call is the seam.
import ast, sets
import typecheck_util  # fail

proc checkTransitions*(d: Decl) =
  let t = d.typeBody
  if t == nil or t.kind != tkSum or t.transitions.len == 0: return
  var variantNames = initHashSet[string]()
  for v in t.variants: variantNames.incl(v.name)
  for tr in t.transitions:
    if tr.`from` notin variantNames:
      fail("Transition Error: '" & tr.`from` & "' is not a variant of " & d.name, tr.span)
    if tr.to notin variantNames:
      fail("Transition Error: '" & tr.to & "' is not a variant of " & d.name, tr.span)
  var isSealed = false
  for a in t.attrs:
    if a.name == "sealed": isSealed = true
  if isSealed and t.variants.len > 0:
    # Every variant must be reachable from the initial (first) variant
    var reachable = [t.variants[0].name].toHashSet
    var grew = true
    while grew:
      grew = false
      for tr in t.transitions:
        if tr.`from` in reachable and tr.to notin reachable:
          reachable.incl(tr.to)
          grew = true
    for v in t.variants:
      if v.name notin reachable:
        fail("Transition Error: sealed type " & d.name & " variant '" & v.name &
             "' is unreachable from initial variant '" & t.variants[0].name & "'", v.span)
