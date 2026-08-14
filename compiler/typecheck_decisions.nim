# compiler/typecheck_decisions.nim
#
# Decision-table validation (spec 6.1): row width, unreachable rows, and
# completeness.
#
# Why this lifts out when most of the checker does not: once a table's rows
# are collected, every question left is about the ROWS and the input types —
# is this row reachable, does any row fire for this combination, is the table
# complete. None of it synthesizes an expression type, so nothing here calls
# back into the synth core and this module sits below it in the checker DAG
# (the same rule typecheck_flow.nim follows).
#
# The one part that DOES need the checker is typing each row's body, so
# collectRows stays in typecheck.nim and hands the rows here.
#
# Two strategies, picked by whether every input column is enumerable:
#   checkExactly  — enumerate every input combination, so gaps and unreachable
#                   rows are PROVEN. Used for bool and fieldless sum types.
#   checkPairwise — compare rows against each other and demand a catch-all.
#                   Used when a column is an open domain (int, str) that
#                   cannot be enumerated.
import ast, ast_query, strutils
import typecheck_util

type
  DecisionRow* = tuple[pats: seq[Pattern], span: Span]
    ## One row of a decision table: a pattern per input column.

const MaxEnumeratedCombos = 4096
  ## Above this, exact enumeration costs more than it is worth and the
  ## pairwise fallback takes over.
  ##
  ## KNOWINGLY DUPLICATED: codegen_table.nim has MaxPackedCombos = 4096 and its
  ## own columnDomains/comboValues with the same mixed-radix logic. Its comment
  ## says the constant is "shared so the two cannot disagree" — it is not, and
  ## they can. Left alone on purpose: the shared home would be ast_query (both
  ## import it), but moving it makes a CHECKER file depend on a BACKEND one or
  ## churns both backends to relocate ~15 lines that have never drifted. Fix it
  ## the day either copy changes.

proc patCovers(a, b: Pattern): bool =
  ## Does pattern a match everything pattern b matches? (per column)
  if a == nil or a.kind == pkWild: return true
  if b == nil or b.kind == pkWild: return false
  if a.kind != b.kind: return false
  case a.kind
  of pkVar: a.name == b.name
  of pkLit: a.litKind == b.litKind and a.litValue == b.litValue
  else: false

proc patValue(p: Pattern): string =
  ## The value a pattern names, or "_" for a wildcard.
  if p == nil: return "_"
  case p.kind
  of pkWild: "_"
  of pkVar: p.name
  of pkLit: p.litValue
  else: "_"

proc rowPatterns*(pat: Pattern): seq[Pattern] =
  ## A row's columns. A tuple pattern is already one per column; anything
  ## else is a single-column row.
  if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]

proc columnDomains*(m: Module, d: Decl, allEnum: var bool,
                    comboCount: var int): seq[seq[string]] =
  ## The values each input column can take. allEnum stays true only when
  ## every column is enumerable (bool / fieldless sum types).
  allEnum = true
  comboCount = 1
  for p in d.fnParams:
    let dom = enumDomain(m, p.typ)
    if dom.len == 0: allEnum = false
    result.add(dom)
    comboCount *= max(dom.len, 1)

proc comboValues(domains: seq[seq[string]], combo: int): seq[string] =
  ## Decode a mixed-radix combination index into one value per column.
  var rem = combo
  for c in countdown(domains.high, 0):
    result.insert(domains[c][rem mod domains[c].len], 0)
    rem = rem div domains[c].len

proc rowMatches(r: DecisionRow, vals: seq[string]): bool =
  ## Does this row fire for this input combination?
  for c in 0 ..< r.pats.len:
    let v = patValue(r.pats[c])
    if v != "_" and v != vals[c]: return false
  true

proc checkRowSymbols(d: Decl, rows: seq[DecisionRow],
                     domains: seq[seq[string]]) =
  ## Symbols in rows must be actual values of the column type.
  for r in rows:
    for c in 0 ..< r.pats.len:
      let v = patValue(r.pats[c])
      if v != "_" and v notin domains[c]:
        fail("Decision Error: '" & v & "' is not a value of " &
             typeName(d.fnParams[c].typ) & " in table '" & d.name & "'", r.span)

proc failGap(d: Decl, vals: seq[string]) =
  ## No row fires for this input combination.
  var desc: seq[string]
  for c in 0 ..< vals.len:
    desc.add(d.fnParams[c].name & ": " & vals[c])
  fail("Decision Error: '" & d.name & "' has a gap — no row matches (" &
       desc.join(", ") & ")", d.span)

proc firstMatchingRow(rows: seq[DecisionRow], vals: seq[string]): int =
  ## The row that fires for this combination, -1 if there is none.
  for i, r in rows:
    if rowMatches(r, vals): return i
  -1

proc checkExactly(d: Decl, rows: seq[DecisionRow], domains: seq[seq[string]],
                  comboCount: int) =
  ## EXACT analysis: every input combination is enumerated, so gaps and
  ## unreachable rows are proven, not approximated.
  checkRowSymbols(d, rows, domains)
  var rowUsed = newSeq[bool](rows.len)
  for combo in 0 ..< comboCount:
    let vals = comboValues(domains, combo)
    let hit = firstMatchingRow(rows, vals)
    if hit < 0: failGap(d, vals)
    rowUsed[hit] = true
  for i, used in rowUsed:
    if not used:
      fail("Decision Error: row " & $(i+1) & " of '" & d.name &
           "' is unreachable — earlier rows cover all its inputs", rows[i].span)

proc coversRow(earlier, later: DecisionRow): bool =
  ## Does an earlier row match everything a later one matches?
  for c in 0 ..< later.pats.len:
    if not patCovers(earlier.pats[c], later.pats[c]): return false
  true

proc checkPairwise(d: Decl, rows: seq[DecisionRow]) =
  ## Open domains: completeness cannot be proven, so check rows against each
  ## other and require a catch-all row.
  for j in 1 ..< rows.len:
    for i in 0 ..< j:
      if coversRow(rows[i], rows[j]):
        fail("Decision Error: row " & $(j+1) & " of '" & d.name &
             "' is unreachable — row " & $(i+1) & " already covers it",
             rows[j].span)
  for p in rows[^1].pats:
    if p != nil and p.kind != pkWild:
      fail("Decision Error: '" & d.name & "' cannot be proven complete — " &
           "end the table with a catch-all row (all _)", d.span)

proc checkRowWidth*(d: Decl, pats: seq[Pattern], sp: Span) =
  ## Every row must have one pattern per declared input.
  if pats.len != d.fnParams.len:
    fail("Decision Error: row in '" & d.name & "' has " & $pats.len &
         " columns but the table declares " & $d.fnParams.len & " inputs", sp)

proc checkDecisionRows*(m: Module, d: Decl, rows: seq[DecisionRow]) =
  ## spec 6.1: unreachable rows and completeness, by whichever strategy the
  ## input types allow.
  var allEnum = true
  var comboCount = 1
  let domains = columnDomains(m, d, allEnum, comboCount)
  if allEnum and comboCount <= MaxEnumeratedCombos:
    checkExactly(d, rows, domains, comboCount)
  else:
    checkPairwise(d, rows)
