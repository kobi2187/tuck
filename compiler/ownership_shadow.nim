# compiler/ownership_shadow.nim
#
# STAGE D's DIFFERENTIAL — the elaborator's answers beside today's, printed,
# never acted on (thoughts/shared/plans/2026-10-05-ownership-rules-
# proposal.md, §5 step 2: "computed beside the old one, every difference
# explained, then switched").
#
# A diagnostic, and a temporary one: it imports the passes the elaborator
# replaces (codegen_common's keep analysis among them) only to compare with
# them, and goes when they do.
#
#   TUCK_DEBUG_OWN=params   rule P beside today's two encodings of it, one
#                           line per owning parameter of every fn:
#                           on Nim, `PARAM <fn> <param> <verdict>` against
#                           `sink` (paramIsMovable); on Odin and D,
#                           `TWIN <fn> <param> <verdict>` against the moved
#                           twin's parameter (movedFnParam) — the only one a
#                           callee consumes there today. A verdict is `same`,
#                           `rules-only` (P consumes, today does not) or
#                           `today-only`.
import os
import ast, ast_query
import resolution
import ownership_elab
from twin_shape import ownsHeap, movedFnParam
from codegen_common import paramIsMovable

let DebugOwn = getEnv("TUCK_DEBUG_OWN")
  ## Read once at module init.

proc verdict(rules, today: bool): string =
  ## How the two answers compare.
  if rules == today: "same"
  elif rules: "rules-only"
  else: "today-only"

proc diffParams*(res: Resolution, m: Module, nim: bool) =
  ## Rule P against today's `sink` (the Nim tree) or moved twins (the Odin
  ## and D trees), per owning parameter.
  if DebugOwn != "params": return
  var memo: ConsumeMemo
  for d in m.allFns:
    if d == nil or d.fnBody == nil: continue
    let moved = if nim: "" else: movedFnParam(res, m, d)
    for p in d.fnParams:
      if not ownsHeap(m, p.typ): continue
      let why = res.consumesWhy(m, d, p.name, memo)
      let rules = why.len > 0
      let today = if nim: paramIsMovable(res, m, d.fnBody, p)
                  else: p.name == moved
      echo (if nim: "PARAM " else: "TWIN "), d.name, " ", p.name, " ",
           verdict(rules, today), (if rules: " (" & why & ")" else: "")
