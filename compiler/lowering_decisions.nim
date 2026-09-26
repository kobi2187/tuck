# compiler/lowering_decisions.nim
#
# DECISION TABLES, LOWERED (ROADMAP M4.2) — a table becomes an ordinary body
# before any backend sees it.
#
#     decision route({priority: Priority, encrypted: bool}) -> int:
#       | High  true  -> 1
#       | High  false -> 2
#       | Low   _     -> 3
#
# Every column enumerable, and few enough combinations: PACKED. Each
# combination is resolved to its first matching row at compile time, the
# combinations are grouped by outcome, and the body becomes one `match` over
# the combination's index:
#
#     match ord(priority) * 2 + ord(encrypted):
#       0: return 2          # High false
#       1: return 1          # High true
#       _: return 3          # every Low
#
# Otherwise CHAINED: the rows in order, each a guard, ending in the catch-all
# row the checker insists an open-domain table has.
#
#     if n == 0: return A
#     return B
#
# WHY HERE. Each of the three emitters built the table itself — its own row
# collection, its own grouping, its own key spelling — and they had drifted:
# D packed a table of any size, where Nim and Odin fell back to a chain above
# 4096 combinations. A table built as a tree is one decision, made once; the
# emitters print a `match` and an `if`, which they already knew how to do.
# And a table the SSA builder cannot see into is a body whose reads it cannot
# record — lowered, it is a body like any other.
#
# The one thing that is genuinely per-target is the ORDINAL of an enum or bool
# (`ord`, `int()` or a ternary, a cast), which is why `exkOrdinal` exists.
import ast, ast_ops, ast_query
import resolution
import decision_table
from parser_stringify import toString

type Row = object
  cols: seq[Pattern]      ## one pattern per parameter
  body: Expr              ## what the row answers

proc isTable(d: Decl): bool =
  ## A `decision` declaration. Its rows are subject-less `match`es, a shape
  ## only the `decision` parser builds.
  d != nil and d.kind == dkFn and d.fnBody != nil and d.isDecision

proc rowsOf(d: Decl): seq[Row] =
  ## Each row is a subject-less `match` with one arm; its pattern is a tuple
  ## (one element per column) or, for a one-column table, a single pattern.
  for s in d.fnBody.stmts:
    if s.kind != exkMatch or s.arms.len == 0: continue
    let pat = s.arms[0].pattern
    let cols = if pat != nil and pat.kind == pkTuple: pat.elems else: @[pat]
    doAssert cols.len == d.fnParams.len,
      "lowering_decisions: a row of " & d.name & " has " & $cols.len &
      " columns for " & $d.fnParams.len & " parameters — the checker rejects that"
    result.add Row(cols: cols, body: s.arms[0].body)

# --- building nodes, typed ---------------------------------------------------
#
# Every node built here is given its type: the emitters ask the checker's
# table what a node is (an Odin ordinal of a bool is a ternary, an enum tag
# qualifies by its type), and a node built after checking has nothing there
# unless it is put there.

proc intType(sp: Span): Type = Type(span: sp, kind: tkNamed, name: "int")
proc boolType(sp: Span): Type = Type(span: sp, kind: tkNamed, name: "bool")

proc paramRef(res: Resolution, d: Decl, i: int): Expr =
  let p = d.fnParams[i]
  res.typed(Expr(span: d.span, kind: exkVar, name: p.name), p.typ)

proc intLit(res: Resolution, sp: Span, n: int): Expr =
  res.typed(Expr(span: sp, kind: exkLit, litKind: lkInt, litValue: $n),
            intType(sp))

proc binary(res: Resolution, op: BinOp, l, r: Expr, t: Type): Expr =
  res.typed(Expr(span: l.span, kind: exkBinary, binOp: op, left: l, right: r), t)

proc returnOf(body: Expr): Expr =
  Expr(span: body.span, kind: exkReturn, returnVal: body)

# --- packed ------------------------------------------------------------------

proc packedKey(res: Resolution, d: Decl, domains: seq[seq[string]],
               comboCount: int): Expr =
  ## `ord(p0) * stride0 + ... + ord(pN)`: mixed radix, the LAST column least
  ## significant — the same order `comboValues` decodes in, which is what
  ## makes key `k` mean combination `k`.
  var stride = comboCount
  for c in 0 ..< domains.len:
    stride = stride div domains[c].len
    var term = res.typed(Expr(span: d.span, kind: exkOrdinal,
                              ordinalOf: res.paramRef(d, c)), intType(d.span))
    if stride > 1:
      term = res.binary(boMul, term, res.intLit(d.span, stride), intType(d.span))
    result = if result == nil: term
             else: res.binary(boAdd, result, term, intType(d.span))

proc keyPattern(sp: Span, keys: seq[int]): Pattern =
  ## `0` for one key, `0, 4, 5` for several — an or-pattern of int literals.
  for k in keys:
    let lit = Pattern(span: sp, kind: pkLit, litKind: lkInt, litValue: $k)
    result = if result == nil: lit
             else: Pattern(span: sp, kind: pkOr, left: result, right: lit)

proc rowStrings(r: Row): seq[string] =
  for p in r.cols: result.add genPatternStr(p)

type Group = object
  text: string            ## the outcome, as written — what groups combos
  row: int                ## the first row answering it; its body is used
  keys: seq[int]

proc groupByOutcome(rows: seq[Row], domains: seq[seq[string]],
                    comboCount: int): seq[Group] =
  ## Every combination resolved to its FIRST matching row (the table's own
  ## rule, applied ahead of time), then grouped by what that row answers, so
  ## two rows answering `2` share one arm. In order of first appearance.
  var pats: seq[seq[string]]
  for r in rows: pats.add rowStrings(r)
  for combo in 0 ..< comboCount:
    let vals = comboValues(domains, combo)
    var hit = -1
    for i in 0 ..< rows.len:
      if rowMatches(pats[i], vals):
        hit = i
        break
    doAssert hit >= 0, "lowering_decisions: no row answers combination " &
      $combo & " — the checker proves an enumerable table complete"
    let text = rows[hit].body.toString()
    var found = false
    for g in result.mitems:
      if g.text == text:
        g.keys.add combo
        found = true
        break
    if not found: result.add Group(text: text, row: hit, keys: @[combo])

proc lowerPacked(res: Resolution, d: Decl, rows: seq[Row],
                 domains: seq[seq[string]], comboCount: int): seq[Expr] =
  let groups = groupByOutcome(rows, domains, comboCount)
  # ONE OUTCOME for every combination: nothing to dispatch on.
  if groups.len == 1: return @[returnOf(rows[groups[0].row].body)]
  var arms: seq[MatchArm]
  for gi, g in groups:
    # The last group is the catch-all, so the match is total over an int.
    let pat = if gi == groups.high: Pattern(span: d.span, kind: pkWild)
              else: keyPattern(d.span, g.keys)
    arms.add MatchArm(pattern: pat, body: returnOf(rows[g.row].body),
                      span: d.span)
  @[Expr(span: d.span, kind: exkMatch,
         subject: res.packedKey(d, domains, comboCount), arms: arms)]

# --- chained -----------------------------------------------------------------

proc columnValue(res: Resolution, d: Decl, i: int, p: Pattern): Expr =
  ## The value a column's pattern names, typed as the column: an enum tag,
  ## an error name, or a literal.
  let t = d.fnParams[i].typ
  case p.kind
  of pkVar: res.typed(Expr(span: p.span, kind: exkVar, name: p.name), t)
  of pkLit:
    res.typed(Expr(span: p.span, kind: exkLit, litKind: p.litKind,
                   litValue: p.litValue), t)
  of pkWild, pkRecord, pkTuple, pkOr:
    raiseAssert "lowering_decisions: a " & $p.kind & " column in " & d.name &
      " — a row's columns are values or `_`"

proc rowCondition(res: Resolution, d: Decl, r: Row): Expr =
  ## `a == X and b == Y` over the columns that are not `_`; nil when every
  ## column is — the catch-all row.
  for i, p in r.cols:
    if p == nil or p.kind == pkWild: continue
    let test = res.binary(boEq, res.paramRef(d, i), res.columnValue(d, i, p),
                          boolType(d.span))
    result = if result == nil: test
             else: res.binary(boAnd, result, test, boolType(d.span))

proc lowerChained(res: Resolution, d: Decl, rows: seq[Row]): seq[Expr] =
  for r in rows:
    let cond = res.rowCondition(d, r)
    if cond == nil:
      # The catch-all. Rows after it are unreachable, which the checker
      # rejects, so it is also the last.
      result.add returnOf(r.body)
      return
    result.add Expr(span: r.body.span, kind: exkIf, cond: cond,
                    thenBranch: Expr(span: r.body.span, kind: exkBlock,
                                     stmts: @[returnOf(r.body)]))
  # A table that does not pack is one the checker could not enumerate, and
  # for exactly those it demands a catch-all last row (checkPairwise).
  raiseAssert "lowering_decisions: " & d.name & " ends without a catch-all " &
    "row, which the checker requires of a table it cannot enumerate"

# --- the pass ----------------------------------------------------------------

proc lowerTable(res: Resolution, m: Module, d: Decl) =
  let rows = rowsOf(d)
  doAssert rows.len > 0, "lowering_decisions: " & d.name & " has no rows"
  let (domains, allEnum, comboCount) = columnDomains(m, d)
  let stmts =
    if allEnum and comboCount > 0 and comboCount <= MaxPackedCombos:
      res.lowerPacked(d, rows, domains, comboCount)
    else:
      res.lowerChained(d, rows)
  d.fnBody = Expr(span: d.fnBody.span, kind: exkBlock, stmts: stmts)

proc lowerDecisionTables*(res: Resolution, m: Module) =
  ## Every decision table in the module, top level and member alike.
  for d in m.allFns():
    if d.isTable: lowerTable(res, m, d)
