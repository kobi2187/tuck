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
#   TUCK_DEBUG_OWN=drops    rules D and M beside Odin's frees, as the Stage C
#                           nodes print them: `DROP <fn> <place> <slot>
#                           <verdict> <fate>` per owned slot at the end of
#                           its scope (a `defer drop`), and `OVERWRITE <fn>
#                           <place> <line:col> <verdict> <fate>` per
#                           reassignment (`dropsOld`). The plan is computed
#                           before step 9 (`planDrops`), from the program as
#                           the rules see it; the nodes are read after it
#                           (`diffDrops`).
import os, tables, sets, strutils
import ast, ast_ops, ast_query
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

var plans: Table[NodeId, DropPlan]
  ## planDrops' answers, per fn, until diffDrops reads them.

proc planDrops*(res: Resolution, m: Module) =
  ## Rules D and M for every fn, before step 9 makes today's nodes.
  if DebugOwn != "drops": return
  for d in m.allFns:
    if d != nil and d.fnBody != nil and d.id.isSet:
      plans[d.id] = dropPlan(res, m, d)

proc todayDrops(body: Expr): tuple[scope: HashSet[string], old: HashSet[NodeId]] =
  ## Stage C's frees in one body: each `defer drop(place)`, by slot key, and
  ## each assignment that drops its old value.
  for n in body.nodes:
    if n.kind == exkDefer and n.deferBody != nil and
       n.deferBody.kind == exkBlock and n.deferBody.stmts.len == 1 and
       n.deferBody.stmts[0].kind == exkDrop:
      let path = pathOf(n.deferBody.stmts[0].dropped)
      let dot = path.find('.')
      result.scope.incl(if dot < 0: slotKey(path, "")
                        else: slotKey(path[0 ..< dot], path[dot + 1 .. ^1]))
    elif n.kind == exkAssign and n.dropsOld:
      result.old.incl n.id

proc fateName(f: Fate): string = ($f)[1 .. ^1].toLowerAscii

proc echoScopeDrops(d: Decl, plan: DropPlan, scope: HashSet[string]) =
  ## One line per owned slot either side drops where its scope ends.
  var keys = scope
  for k in plan.scopeEnd.keys: keys.incl k
  for k in keys:
    let fate = plan.scopeEnd.getOrDefault(k, fMoved)
    let parts = k.split('\t')
    echo "DROP ", d.name, " ", parts[0], " ",
         (if parts[1].len == 0: "-" else: parts[1]), " ",
         verdict(fate != fMoved, k in scope),
         (if k in plan.scopeEnd: " " & fateName(fate) else: " unowned"),
         (if parts[0] in plan.strs: " str" else: "")

proc echoOverwrites(d: Decl, plan: DropPlan, old: HashSet[NodeId]) =
  ## One line per reassignment either side drops the old value at.
  for n in d.fnBody.nodes:
    if n.kind != exkAssign or (n.id notin old and n.id notin plan.overwrite):
      continue
    let fate = plan.overwrite.getOrDefault(n.id, fMoved)
    echo "OVERWRITE ", d.name, " ", pathOf(n.target), " ", n.span.line, ":",
         n.span.col, " ", verdict(fate != fMoved, n.id in old),
         (if n.id in plan.overwrite: " " & fateName(fate) else: " unowned")

proc diffDrops*(res: Resolution, m: Module) =
  ## The rules' drops against the nodes Stage C made from today's.
  if DebugOwn != "drops": return
  for d in m.allFns:
    if d == nil or d.fnBody == nil or d.id notin plans: continue
    let (scope, old) = todayDrops(d.fnBody)
    echoScopeDrops(d, plans[d.id], scope)
    echoOverwrites(d, plans[d.id], old)
