## cost_model — a coarse, static worst-case CYCLE score for one declaration.
##
## This is the scoring function behind the `period:` / `deadline:` work. It is
## deliberately NOT a WCET tool: it walks the checked AST with a small table of
## per-node costs, takes the worst branch, and multiplies a loop body by its
## trip count when that count is constant-foldable. It knows nothing about
## pipelines, flash wait states, bus arbitration or interrupt interference.
##
## Honesty is part of the API. `CostScore.cycles` is only an upper bound when
## `notes` is empty; every unmodelled or unprovable part appends a note saying
## so, and the report prints the result as approximate. A score with notes is
## a floor for planning, never a guarantee for a deadline.
##
## A declared deadline is passed in as a budget in cycles by `Decl.id` (the
## syntax that fills the table does not exist yet). It becomes that decl's
## effective cost for its callers, and an estimate above it is reported as a
## violation — without ever lowering the number a caller sees.

import std/[tables, options]
import ast, ast_ops, ast_query, resolution

type
  CostNote* = object
    site*: Span
    text*: string

  CostScore* = object
    cycles*: int
    notes*: seq[CostNote]   ## empty == a bounded, fully modelled estimate

  ScoreCtx = object
    res: Resolution
    m: Module
    budgets: Table[NodeId, int]
    memo: Table[NodeId, CostScore]
    stack: seq[NodeId]

const
  CallOverhead = 4
  LoopOverhead = 2

proc baseCycles(e: Expr): int =
  ## One small weight per AST node kind, named exhaustively on purpose: a new
  ## node kind must be placed here instead of silently inheriting a default.
  result = case e.kind
  of exkLit, exkVar, exkAbsent, exkWrapOk, exkOrdinal, exkBreak, exkContinue,
     exkDiscard, exkTripleDot, exkImport, exkActorRef, exkRegisterRef,
     exkRegistryRef, exkPoolRef, exkMixinRef: 1
  of exkField, exkQualified, exkCast, exkBinary, exkUnary, exkAssign,
     exkReturn, exkCombinator, exkValidate, exkIfaceIs, exkIfacePayload,
     exkBlock, exkCritical, exkDefer: 2
  of exkStruct, exkList, exkFill, exkBracket, exkBracketAssign, exkChain,
     exkSend, exkAcquire, exkFinish, exkIfaceCall, exkRaise, exkSelect,
     exkPoolOp, exkSlabRef, exkSlabOp, exkArenaRef, exkArenaReset,
     exkSlabCell, exkAppend, exkCopy, exkDrop, exkReset: 3
  of exkCall: CallOverhead
  # These four cost their condition/iterable plus a structural child walk;
  # the branches themselves are scored by scoreExpr, not here.
  of exkIf, exkMatch, exkFor, exkWhile: 2

proc addNote(s: var CostScore, site: Span, text: string) =
  s.notes.add CostNote(site: site, text: text)

proc combine(a, b: CostScore): CostScore =
  result.cycles = a.cycles + b.cycles
  result.notes = a.notes & b.notes

proc worst(a, b: CostScore): CostScore =
  ## Sequential cost is a sum; a branch is the MAXIMUM of its arms because the
  ## analyzer does not know which one runs. Notes from both arms survive: the
  ## chosen arm is a runtime fact, not a compile-time one.
  if a.cycles >= b.cycles:
    result = combine(a, b)
  else:
    result = combine(b, a)

proc tripCount(m: Module, e: Expr): Option[int] =
  ## `for i in lo .. hi` has a range expression in the AST. Only a constant
  ## fold on BOTH ends gives a provable trip count; a parameter, a const that
  ## the checker cannot evaluate, or a sequence iterable gives none.
  let it = e.iterable
  if it == nil or it.kind != exkBinary: return none(int)
  if it.binOp notin {boRangeIncl, boRangeExcl}: return none(int)
  let lo = evalConstExpr(m, it.left)
  let hi = evalConstExpr(m, it.right)
  if lo.isNone or hi.isNone: return none(int)
  let n = if it.binOp == boRangeIncl: hi.get - lo.get + 1 else: hi.get - lo.get
  some(max(0, n))

proc scoreDeclIn(d: Decl, ctx: var ScoreCtx): CostScore
proc scoreExpr(e: Expr, ctx: var ScoreCtx): CostScore

proc scoreCall(e: Expr, ctx: var ScoreCtx): CostScore =
  result = CostScore(cycles: baseCycles(e))
  for a in e.args:
    result = combine(result, scoreExpr(a, ctx))
  let c = calleeDecl(ctx.res, ctx.m, e)
  if c == nil:
    result.addNote e.span, "callee cost unknown (unresolved call)"
  elif c.fnBody == nil:
    result.addNote e.span, "callee has no body; cost not modelled"
  elif c.id in ctx.stack:
    result.addNote e.span, "recursive call; no finite bound"
  else:
    result = combine(result, scoreDeclIn(c, ctx))
  if c != nil and hasIo(c.fnEffects):
    result.addNote e.span, "IO cost not modelled"

proc scoreFor(e: Expr, ctx: var ScoreCtx): CostScore =
  result = CostScore(cycles: baseCycles(e))
  result = combine(result, scoreExpr(e.iterable, ctx))
  let body = scoreExpr(e.body, ctx)
  let n = tripCount(ctx.m, e)
  if n.isSome:
    result.cycles += (body.cycles + LoopOverhead) * n.get
    result.notes = result.notes & body.notes
  else:
    result = combine(result, body)
    result.addNote e.span, "loop bound not provable; body counted once"

proc scoreExpr(e: Expr, ctx: var ScoreCtx): CostScore =
  if e == nil: return CostScore()
  case e.kind
  of exkCall:
    result = scoreCall(e, ctx)
  of exkIf:
    result = combine(scoreExpr(e.cond, ctx),
                     worst(scoreExpr(e.thenBranch, ctx),
                           scoreExpr(e.elseBranch, ctx)))
  of exkMatch:
    result = scoreExpr(e.subject, ctx)
    var arms: CostScore
    var haveArm = false
    for arm in e.arms:
      let one = scoreExpr(arm.body, ctx)
      arms = if haveArm: worst(arms, one) else: one
      haveArm = true
    result = combine(result, arms)
  of exkFor:
    result = scoreFor(e, ctx)
  of exkWhile:
    result = combine(scoreExpr(e.whileCond, ctx), scoreExpr(e.whileBody, ctx))
    result.addNote e.span, "unbounded loop has no static bound"
  else:
    result = CostScore(cycles: baseCycles(e))
    for ch in e.children:
      result = combine(result, scoreExpr(ch, ctx))

proc scoreDeclIn(d: Decl, ctx: var ScoreCtx): CostScore =
  if d.id in ctx.memo: return ctx.memo[d.id]
  if d.id in ctx.stack:
    var r = CostScore()
    r.addNote d.span, "recursive call; no finite bound"
    return r
  ctx.stack.add d.id
  let bodyScore = scoreExpr(d.fnBody, ctx)
  discard ctx.stack.pop
  result = bodyScore
  if d.id in ctx.budgets:
    let budget = ctx.budgets[d.id]
    if result.cycles > budget:
      result.addNote d.span, "estimate " & $result.cycles &
        " cycles exceeds declared max " & $budget
    # A declared deadline is the function's cap for its callers. Taking the
    # larger of the two means a bad declaration can never hide its own
    # overrun from the functions that call it.
    result.cycles = max(result.cycles, budget)
  ctx.memo[d.id] = result

proc scoreDecl*(res: Resolution, m: Module, d: Decl,
                budgets: Table[NodeId, int]): CostScore =
  ## The scoring function. `budgets` is keyed by `Decl.id` and holds declared
  ## maximum cycles; pass an empty table until `deadline:` syntax exists.
  var ctx = ScoreCtx(res: res, m: m, budgets: budgets)
  if d == nil or d.fnBody == nil:
    result.addNote d.span, "no body to score"
  else:
    result = scoreDeclIn(d, ctx)

proc scoreDecl*(res: Resolution, m: Module, d: Decl): CostScore =
  scoreDecl(res, m, d, initTable[NodeId, int]())
