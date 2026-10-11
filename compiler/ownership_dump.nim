# compiler/ownership_dump.nim
#
# THE RULES' DECISIONS, PRINTED — a diagnostic, for reading and for the
# `ownership_rules` suite's pins. Each dump is one line per decision, names
# as mangled:
#
#   TUCK_DEBUG_OWN=params   rule P, per owning parameter of every fn:
#                           `PARAM <fn> <param> consumes (<why>)` or
#                           `PARAM <fn> <param> borrows`.
#   TUCK_DEBUG_OWN=drops    rules D and M, per owned slot at the end of its
#                           scope: `DROP <fn> <place> <slot> <fate>` (`-` for
#                           the whole value); fate `owned` (dropped), `moved`
#                           (nobody drops it) or `maybe` (dropped, and reset
#                           where it moves).
#   TUCK_DEBUG_OWN=copies   rule S as written into the tree, per copy:
#                           `COPY <fn> <line:col> <kind>`, kind `seq`,
#                           `deep` or `static` (rule G).
#
# `TUCK_DEBUG_OWN=uses` (rule U) is `ownership_rules.dumpUses`, and
# `TUCK_DEBUG_OWN=verify` (rule V) is `ownership_check.verifyTree`.
import os, tables, strutils
import ast, ast_ops, ast_query
import resolution
import ownership_elab

let DebugOwn = getEnv("TUCK_DEBUG_OWN")
  ## Read once at module init.

proc dumpParams*(res: Resolution, m: Module) =
  ## Rule P, per owning parameter.
  if DebugOwn != "params": return
  var memo: ConsumeMemo
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    for p in d.fnParams:
      if not res.owning(m, p.typ): continue
      let why = res.consumesWhy(m, d, p.name, memo)
      echo "PARAM ", d.name, " ", p.name, " ",
           (if why.len > 0: "consumes (" & why & ")" else: "borrows")

proc fateName(f: Fate): string = ($f)[1 .. ^1].toLowerAscii

proc dumpDrops*(res: Resolution, m: Module) =
  ## Rules D and M, per owned slot where its scope ends. Before the rules
  ## write the tree: the plan is made from the program as written.
  if DebugOwn != "drops": return
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    let plan = dropPlan(res, m, d)
    for k, fate in plan.scopeEnd:
      let parts = k.split('\t')
      echo "DROP ", d.name, " ", parts[0], " ",
           (if parts[1].len == 0: "-" else: parts[1]), " ", fateName(fate)

proc dumpCopies*(m: Module) =
  ## Rule S, per copy the rules wrote into the tree.
  if DebugOwn != "copies": return
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    for n in d.fnBody.nodes:
      if n.kind == exkCopy:
        echo "COPY ", d.name, " ", n.span.line, ":", n.span.col, " ",
             ($n.copyKind)[2 .. ^1].toLowerAscii
