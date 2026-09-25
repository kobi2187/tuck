# compiler/decision_table.nim
#
# The combinatorics behind decision-table compilation (spec 6.1).
#
# What a decision table does: when every input column has a small enumerable
# set of values, a whole table of rules collapses into ONE `match` over a
# packed integer key — every combination resolved at compile time and grouped
# by outcome, so the running program does zero comparisons.
#
# This file holds the part of that which is PURE ARITHMETIC: each column's
# value set, decoding a combination index into column values, and whether a
# row's patterns accept them. `lowering_decisions` builds the table's code
# from it. It was `codegen_table.nim` while three emitters each built the
# table's text themselves; lowering the table moved the one consumer out of
# codegen, and the name followed.
import ast, ast_query

const MaxPackedCombos* = 4096
  ## Above this many combinations the packed table stops being worth it and
  ## the table lowers to a comparison chain instead.

proc columnDomains*(m: Module, d: Decl): (seq[seq[string]], bool, int) =
  ## Each param's enumerable value set, whether ALL of them are enumerable,
  ## and how many combinations that makes. Only an all-enumerable table can
  ## collapse to a packed key.
  var domains: seq[seq[string]]
  var allEnum = true
  var comboCount = 1
  for p in d.fnParams:
    let dom = enumDomain(m, p.typ)
    if dom.len == 0: allEnum = false
    domains.add(dom)
    comboCount *= max(dom.len, 1)
  (domains, allEnum, comboCount)

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
