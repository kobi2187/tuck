# compiler/typecheck_flow.nim
#
# Control-flow and variant-narrowing analysis for the type checker: the spec
# 4.4b transition tracking (which variants a tracked var can hold), branch/loop
# merge of variant sets, and the early-return-guard narrowing. Pure with respect
# to synthesis — nothing here calls back into the synth core, so it sits below
# it in the checker DAG. Operates on a TypeChecker from typecheck_state.
import ast, tables, sets, strutils
import typecheck_util
import typecheck_state



# --- spec 4.4b: static transition checking --------------------------------
# A sum type with a `transitions:` block is TRACKED: every var of it carries
# the set of variants it could statically be in (Type@Variant in
# diagnostics). A reassignment that changes variant is checked against the
# table at compile time; branch/loop merges union the sets; anything
# unprovable is an error — never a silent runtime fallback.

proc transType*(tc: TypeChecker, t: Type): string =
  ## the declared name of a transitions-carrying sum type, or ""
  if t == nil or t.kind != tkNamed or not tc.typeDecls.hasKey(t.name): return ""
  let body = tc.typeDecls[t.name]
  if body.kind == tkSum and body.transitions.len > 0: return t.name
  ""

## PRECONDITION for allVariants and hasEdge: `typeName` names a declared type.
## Both index tc.typeDecls directly and raise KeyError if it does not.
##
## Every caller establishes this first, in one of two ways. Most pass a
## transType result, which returns "" for anything undeclared and is checked
## against "" before use. The exception is checkDecisionTable
## (typecheck.nim:708), which computes a match's coverage domain over ANY sum
## type, not just a transitions-carrying one — so it does its own hasKey ahead
## of the call. Guarding in here instead would be dead code today; keep the
## precondition, and if a third kind of caller appears, give it a total
## variant rather than making these two lie about their domain.

proc allVariants*(tc: TypeChecker, typeName: string): seq[string] =
  for v in tc.typeDecls[typeName].variants: result.add(v.name)

proc hasEdge*(tc: TypeChecker, typeName, frm, to: string): bool =
  for tr in tc.typeDecls[typeName].transitions:
    if tr.`from` == frm and tr.to == to: return true
  false

proc checkTransSet*(tc: var TypeChecker, typeName: string,
                   cur, next: seq[string], sp: Span) =
  # legal iff every target is reachable from EVERY member of the current set
  for to in next:
    for frm in cur:
      if frm == to: continue  # same-variant reassignment: payload refresh
      if not tc.hasEdge(typeName, frm, to):
        fail("Transition Error: " & typeName & " cannot go " & frm & " -> " &
             to & " (value is " & typeName & "@{" & cur.join("|") &
             "}; that edge is not in the transitions table)", sp)

# Which variant set an RHS provides. Traceability is syntactic:
# constructions give a singleton, var copies give the var's set, a fn whose
# every return is a traceable construction gives their union — anything
# else is the full set (all variants possible).
proc fnReturnVariants*(tc: TypeChecker, fnName, typeName: string): seq[string]

proc exprVariants*(tc: TypeChecker, typeName: string, e: Expr): seq[string] =
  if e == nil: return tc.allVariants(typeName)
  case e.kind
  of exkField:
    # bare Type.Variant (incl. [unsafe])
    if e.receiver != nil and e.receiver.kind == exkVar and
       e.receiver.name == typeName:
      return @[e.fieldName]
  of exkCall:
    # {payload} Type.Variant
    if e.callee != nil and e.callee.kind == exkField and
       e.callee.receiver != nil and e.callee.receiver.kind == exkVar and
       e.callee.receiver.name == typeName:
      return @[e.callee.fieldName]
    # {args} someFn — trace the callee's return sites
    if e.callee != nil and e.callee.kind == exkVar:
      return tc.fnReturnVariants(e.callee.name, typeName)
  of exkVar:
    if tc.varVariants.hasKey(e.name):
      return tc.varVariants[e.name]
  else: discard
  tc.allVariants(typeName)

proc scanReturns*(tc: TypeChecker, typeName: string, e: Expr,
                 acc: var seq[string], exact: var bool) =
  if e == nil or not exact: return
  case e.kind
  of exkReturn:
    if e.returnVal == nil:
      exact = false
      return
    let vs = tc.exprVariants(typeName, e.returnVal)
    # only constructions count as traceable inside a body scan (var sets
    # are flow-dependent and this is a syntactic pre-pass)
    if vs.len == 1:
      for v in vs:
        if v notin acc: acc.add(v)
    else:
      exact = false
  of exkBlock:
    for s in e.stmts: tc.scanReturns(typeName, s, acc, exact)
  of exkIf:
    tc.scanReturns(typeName, e.thenBranch, acc, exact)
    tc.scanReturns(typeName, e.elseBranch, acc, exact)
  of exkMatch:
    for arm in e.arms: tc.scanReturns(typeName, arm.body, acc, exact)
  of exkFor:
    tc.scanReturns(typeName, e.body, acc, exact)
  of exkWhile:
    tc.scanReturns(typeName, e.whileBody, acc, exact)
  else: discard


proc collectFieldReads*(param: string, e: Expr, acc: var HashSet[string]) =
  ## Every `param.field` read in this subtree.
  ##
  ## A syntactic pre-pass over a callee's body, same shape as fnReturnVariants
  ## below. Writes are not distinguished because a parameter cannot be written
  ## through at all (TK-TY15), so every occurrence is a read.
  ##
  ## Walks EVERY child via ast.children rather than the handful of kinds
  ## scanReturns visits: a read can appear anywhere an expression can, and a
  ## missed one fails OPEN — the caller would be told its hole is unused when
  ## the callee does read it.
  if e == nil: return
  if e.kind == exkField and e.receiver != nil and
     e.receiver.kind == exkVar and e.receiver.name == param:
    acc.incl(e.fieldName)
  for c in e.children: collectFieldReads(param, c, acc)

proc namesVar(e: Expr, name: string): bool =
  e != nil and e.kind == exkVar and e.name == name

proc assignedField(target: Expr, name: string, acc: var HashSet[string]) =
  ## `name.f = v` — f is given a value.
  if target != nil and target.kind == exkField and
     namesVar(target.receiver, name):
    acc.incl(target.fieldName)

proc constructedFields(e: Expr, name: string, acc: var HashSet[string]) =
  ## `var name = {a: 1, b: 2} T` — a construction supplies exactly what it
  ## lists, so binding one to the returned local fills those fields.
  if not (e.isDecl and namesVar(e.target, name)): return
  let v = e.assignVal
  if v == nil or v.kind != exkCall or v.args.len != 1: return
  if v.args[0] == nil or v.args[0].kind != exkStruct: return
  for f in v.args[0].fields: acc.incl(f.name)

proc chainSetFields(e: Expr, name: string, acc: var HashSet[string]) =
  ## `name ..f {v}` — every step that names a field sets it. A step naming a
  ## FN is a nested mutator; not followed, so it credits nothing (the safe
  ## direction, see collectFieldWrites).
  if not namesVar(e.base, name): return
  for s in e.steps:
    if s.target != nil and s.target.kind == exkVar: acc.incl(s.target.name)

proc collectFieldWrites*(target: string, e: Expr, acc: var HashSet[string]) =
  ## Every field `target` is given a value in this subtree — `t.f = v`,
  ## `t ..f {v}`, and the fields of a construction bound to it.
  ##
  ## The mirror of collectFieldReads, and its soundness runs the OTHER WAY.
  ## A missed read fails open (a bad call slips through); a missed write fails
  ## CLOSED — a hole the mutator did fill is still reported, which is a false
  ## error on working code. So this only ever credits what it can prove, and
  ## anything it cannot see leaves the hole marked. Visible and fixable
  ## (set the field at the call site) rather than silently wrong.
  if e == nil: return
  case e.kind
  of exkAssign:
    assignedField(e.target, target, acc)       # t.f = v
    constructedFields(e, target, acc)          # var t = {a: 1} T
  of exkChain:
    chainSetFields(e, target, acc)             # t ..f {v}
  else: discard
  for c in e.children: collectFieldWrites(target, c, acc)

proc mutatorFillsFields*(tc: TypeChecker, fnName: string): HashSet[string] =
  ## The fields a `..fn` mutator provably gives a value to.
  ##
  ## A mutator is `fn f({self: T}) -> T`: it copies self, sets fields, returns
  ## the copy. Scanning what it writes to the RETURNED name is what lets
  ## `c ..configure` fill holes without clearing ones it never touched.
  ##
  ## Empty for anything unscannable — an imported or pending fn, or a body
  ## whose returned value is not a plain local. See collectFieldWrites for why
  ## erring empty is the safe direction here.
  if not tc.fnDecls.hasKey(fnName): return
  let d = tc.fnDecls[fnName]
  if d == nil or d.kind != dkFn or d.fnBody == nil: return
  # Which local is returned? Only a bare `return name` is traceable.
  var returned = ""
  for s in d.fnBody.children:
    if s != nil and s.kind == exkReturn and s.returnVal != nil and
       s.returnVal.kind == exkVar:
      returned = s.returnVal.name
  if returned == "": return
  collectFieldWrites(returned, d.fnBody, result)

proc uninitFieldsRead*(tc: TypeChecker, fnName, param: string,
                       holes: HashSet[string]): seq[string] =
  ## Which of `holes` the named fn actually reads off `param`.
  ##
  ## Empty means the callee never touches them, so passing a partly-built
  ## record is fine. An unknown callee (imported, pending, a fn slot) has no
  ## body to scan and answers empty too — permissive, matching how the rest of
  ## the checker degrades when it cannot see something.
  if not tc.fnDecls.hasKey(fnName): return @[]
  let d = tc.fnDecls[fnName]
  if d == nil or d.kind != dkFn or d.fnBody == nil: return @[]
  var reads: HashSet[string]
  collectFieldReads(param, d.fnBody, reads)
  for h in holes:
    if h in reads: result.add(h)

proc fnReturnVariants*(tc: TypeChecker, fnName, typeName: string): seq[string] =
  for d in tc.module.decls:
    if d != nil and d.kind == dkFn and d.name == fnName and
       d.fnReturnType != nil and d.fnReturnType.kind == tkNamed and
       d.fnReturnType.name == typeName and d.fnBody != nil:
      var acc: seq[string]
      var exact = true
      tc.scanReturns(typeName, d.fnBody, acc, exact)
      # the implicit tail return is a plain trailing expression
      if d.fnBody.kind == exkBlock and d.fnBody.stmts.len > 0:
        let last = d.fnBody.stmts[^1]
        if last.kind notin {exkReturn, exkIf, exkMatch, exkFor, exkWhile,
                            exkBreak, exkContinue, exkBlock, exkAssign}:
          let vs = tc.exprVariants(typeName, last)
          if vs.len == 1:
            for v in vs:
              if v notin acc: acc.add(v)
          else:
            exact = false
      if exact and acc.len > 0: return acc
      return tc.allVariants(typeName)
  tc.allVariants(typeName)


proc mergeVariants*(a, b: Table[string, seq[string]]): Table[string, seq[string]] =
  result = a
  for k, v in b:
    if result.hasKey(k):
      var merged = result[k]
      for x in v:
        if x notin merged: merged.add(x)
      result[k] = merged
    else:
      result[k] = v

proc alwaysExits*(e: Expr): bool =
  ## True when control cannot fall out the bottom of this branch — the
  ## condition that lets an early-return guard narrow what follows it.
  if e == nil: return false
  case e.kind
  of exkReturn, exkRaise, exkBreak, exkContinue: true
  of exkBlock:
    e.stmts.len > 0 and alwaysExits(e.stmts[^1])
  of exkIf:
    # only if BOTH sides exit; a missing else can fall through
    e.elseBranch != nil and alwaysExits(e.thenBranch) and
      alwaysExits(e.elseBranch)
  of exkMatch:
    if e.arms.len == 0: return false
    for arm in e.arms:
      if not alwaysExits(arm.body): return false
    true
  else: false

proc earlyReturnGuard*(s: Expr): string =
  ## `if not r.ok: <exits>` — the name of the result it proves present for
  ## everything after this statement, or "" when the shape does not match.
  if s == nil or s.kind != exkIf or s.cond == nil: return ""
  if not alwaysExits(s.thenBranch): return ""
  if s.elseBranch != nil: return ""   # an else means the guard is not a bail
  let c = s.cond
  if c.kind != exkUnary or c.unaryOp != uoNot or c.operand == nil: return ""
  let inner = c.operand
  if inner.kind != exkField or inner.fieldName != "ok": return ""
  if inner.receiver == nil or inner.receiver.kind != exkVar: return ""
  inner.receiver.name
