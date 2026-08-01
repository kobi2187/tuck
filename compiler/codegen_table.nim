# compiler/codegen_table.nim
#
# The combinatorics behind decision-table compilation (spec 6.1), split out of
# codegen.nim.
#
# What a decision table does: when every input column has a small enumerable
# set of values, a whole table of rules collapses into ONE `case` over a packed
# integer key — every combination resolved at compile time and grouped by
# outcome, so the running program does zero comparisons.
#
# This file holds the part of that which is PURE ARITHMETIC over strings:
# decode a combination index into column values, ask whether a row's patterns
# accept them, resolve first-match-wins ahead of time, group identical
# outcomes, and build the mixed-radix key expression. None of it touches
# CodegenCtx, so none of it can reach back into expression emission.
#
# What stayed in codegen.nim: decisionRows and genPackedTable/genConditionChain,
# because they call ctx.genExpr to emit the row bodies. That call is exactly
# the seam — above it lives the recursive backend, below it lives this.
#
# packedKeyExpr emits `ord(param) * stride` in Nim spelling. That is the one
# target-language detail here; the Odin backend builds its own tables rather
# than sharing it (share the logic, never share the syntax).
import ast, strutils

proc comboValues*(domains: seq[seq[string]], combo: int): seq[string] =
  ## The column values this combination index stands for, decoded mixed-radix.
  result = newSeq[string](domains.len)
  var rem = combo
  for c in countdown(domains.high, 0):
    result[c] = domains[c][rem mod domains[c].len]
    rem = rem div domains[c].len

proc rowMatches*(row, vals: seq[string]): bool =
  ## Does this row's pattern accept these column values? `_` matches anything.
  for c in 0 ..< row.len:
    if row[c] != "_" and row[c] != vals[c]: return false
  true

proc firstOutcome*(rowPats: seq[seq[string]], bodies: seq[string],
                   vals: seq[string]): string =
  ## The body of the first row matching these values — the table's own
  ## first-match-wins rule, applied ahead of time.
  for i in 0 ..< rowPats.len:
    if rowMatches(rowPats[i], vals): return bodies[i]
  ""

proc groupByOutcome*(domains: seq[seq[string]], comboCount: int,
                     rowPats: seq[seq[string]],
                     bodies: seq[string]): seq[tuple[outcome: string, keys: seq[int]]] =
  ## Every combination resolved to its outcome, then grouped so identical
  ## outcomes share one `of` arm.
  for combo in 0 ..< comboCount:
    let outcome = firstOutcome(rowPats, bodies, comboValues(domains, combo))
    var found = false
    for g in result.mitems:
      if g.outcome == outcome:
        g.keys.add(combo)
        found = true
        break
    if not found: result.add((outcome, @[combo]))

proc packedKeyExpr*(d: Decl, domains: seq[seq[string]], comboCount: int): string =
  ## The mixed-radix key: each column's ord() scaled by the stride of the
  ## columns to its right, summed.
  var parts: seq[string]
  var stride = comboCount
  for c in 0 ..< domains.len:
    stride = stride div domains[c].len
    if stride > 1: parts.add("ord(" & d.fnParams[c].name & ") * " & $stride)
    else: parts.add("ord(" & d.fnParams[c].name & ")")
  parts.join(" + ")
