# compiler/lowering_block_arms.nim
#
# A VALUE `match` WHOSE ARM IS A BLOCK, LOWERED (ruled 2026-11-24: the
# block's last line is the arm's value).
#
#     let x = match n:
#       1: 10
#       _:
#         let d = n * 2
#         d + 1
#
# No backend can print a block where a value goes: Nim's `case` expression
# wants an expression per branch, Odin's value match is a ternary chain, D's
# a lambda over `return <expr>`. So the match becomes its statement form, each
# arm handing its value to the place the match was going to:
#
#     let x: int = zero            # exkZero: the type's zero, set on every path
#     match n:
#       1: x = 10
#       _:
#         let d = n * 2
#         x = d + 1
#
# `return match ...` becomes a match whose arms each `return` their value, and
# so does a value-returning body's tail match. An assignment `y = match ...`
# assigns in each arm. A match the checker accepted anywhere else (only these
# heads parse) would reach the emitters unlowered and fail loudly there.
#
# An arm whose value is itself such a match is a headed statement once it is
# an assignment or a return, so it is lowered in turn.
import ast, ast_ops, ast_query
import resolution

proc lowerIn(res: Resolution, e: Expr)

proc needsLowering(m: Expr): bool =
  ## Is `m` a value match one of whose arms is a block, at any depth of arm
  ## values?
  if m == nil or m.kind != exkMatch or m.subject == nil: return false
  for arm in m.arms:
    if arm.body == nil: continue
    if arm.body.kind == exkBlock or needsLowering(arm.body): return true
  false

proc handing(res: Resolution, v: Expr, give: proc(v: Expr): Expr): Expr =
  ## An arm's body `v` with its value handed on by `give`: the last line of
  ## a block, or the whole of a one-line arm.
  if v.kind == exkBlock and v.stmts.len > 0:
    var stmts = v.stmts
    stmts[^1] = give(stmts[^1])
    return Expr(span: v.span, kind: exkBlock, stmts: stmts)
  Expr(span: v.span, kind: exkBlock, stmts: @[give(v)])

proc statementForm(res: Resolution, m: Expr, give: proc(v: Expr): Expr): Expr =
  ## `m` as a statement match, each arm's value handed on by `give`.
  for arm in m.arms.mitems:
    if arm.body != nil: arm.body = res.handing(arm.body, give)
  m

proc assignTo(res: Resolution, target: Expr): proc(v: Expr): Expr =
  ## Hands a value to `target`: `target = v`.
  result = proc(v: Expr): Expr =
    Expr(span: v.span, kind: exkAssign, target: res.freshCopy(target), assignVal: v)

proc returning(v: Expr): Expr =
  ## Hands a value back from the fn: `return v`.
  Expr(span: v.span, kind: exkReturn, returnVal: v)

proc lowerStmt(res: Resolution, s: Expr): seq[Expr] =
  ## The statements `s` becomes: itself, or a value match it heads in its
  ## statement form (after a zero declaration for a binding).
  case s.kind
  of exkAssign:
    let m = s.assignVal
    if not needsLowering(m): return @[s]
    if s.isDecl and s.target != nil and s.target.kind == exkVar:
      let t = if res.typeFor(s.target) != nil: res.typeFor(s.target)
              else: res.typeFor(m)
      if s.declType == nil: s.declType = t
      s.assignVal = res.typed(Expr(span: m.span, kind: exkZero), t)
      return @[s, res.statementForm(m, res.assignTo(s.target))]
    @[res.statementForm(m, res.assignTo(s.target))]
  of exkReturn:
    if not needsLowering(s.returnVal): return @[s]
    @[res.statementForm(s.returnVal, returning)]
  else: @[s]

proc lowerIn(res: Resolution, e: Expr) =
  ## Every headed value match with a block arm under `e`. The statements a
  ## rewrite produces are walked again, which lowers a nested one.
  if e == nil: return
  if e.kind == exkBlock:
    var stmts: seq[Expr]
    for s in e.stmts:
      if s == nil: stmts.add s
      else: stmts.add res.lowerStmt(s)
    e.stmts = stmts
  for c in e.children: res.lowerIn(c)

proc lowerBlockArms*(res: Resolution, m: Module) =
  ## Every value match with a block arm in the module's bodies. A value
  ## body's tail match is its return value, made explicit first.
  for d in m.allDecls:
    if d.kind in {dkFn, dkTask} and d.fnBody != nil and
       d.fnReturnType != nil and
       not (d.fnReturnType.kind == tkNamed and d.fnReturnType.name == "void"):
      let v = implicitTailValue(d.fnBody)
      if v != nil and needsLowering(v): injectTailReturn(d.fnBody)
  for body in m.bodies: res.lowerIn(body)
