# compiler/complexity.nim
#
# THE SIZE BUDGET — a function may not exceed a branch count or a line count.
#
# Two numbers, measured in one walk of each function body:
#
#   CYCLOMATIC COMPLEXITY — how many independent paths run through the body.
#   Standard McCabe: start at 1 and add one for every point the flow forks.
#   It is a proxy for how many cases a reader (and a test suite) must hold at
#   once. A fn of complexity 12 needs twelve tests to cover its paths; a fn of
#   complexity 3 needs three.
#
#   LINES — last source line of the body minus the first. Spans carry only a
#   start line (ast.Span has line/col, no end), so the extent is recovered by
#   sweeping the subtree for its min and max. That makes the count the lines
#   the body actually SPANS, blank and comment lines included: a body split
#   over 40 lines is a 40-line body however few of them carry tokens.
#
# WHY BOTH. They fail differently. A flat 200-line sequence of assignments has
# complexity 1 and is still unreadable; a 6-line fn with four nested guards is
# short and still hard. Neither number alone catches both shapes.
#
# THE TABULAR EXEMPTION — this is the interesting rule. A `match` or an
# `on select` costs NOTHING for the construct itself: not +1 per arm, and not
# even +1 for opening one. Their arm bodies are still fully measured, and only
# their lines are excluded from the line budget.
#
# The reason is that Tuck already forces matches to be exhaustive (see
# typecheck's dcTyNotExhaustive). Charging per arm would mean the compiler
# demands you handle every variant with one rule and then fines you for the
# length with another — the author would be pushed into splitting a table that
# reads perfectly well as a table, or worse, into a non-exhaustive `if` chain
# to dodge the count. A rule that pressures authors toward the weaker construct
# is a broken rule.
#
# The distinction being drawn is BRANCHING LOGIC versus a TABLE. Nested ifs
# compose: each one multiplies the states a reader tracks. Match arms do not
# compose — they are mutually exclusive rows, read one at a time, and adding a
# row does not complicate the rows already there. So dispatching over twenty
# variants is free, while a match hiding real logic INSIDE its arms is caught
# in full: the arm bodies are walked exactly like any other code. It is the
# tabulation that is free, never what the rows do.
#
# Guards are the exception within the exception. `of X if cond:` is a
# condition, not a row — it costs +1, because it is branching logic that
# happens to be written in a table.
#
# Same argument applies to `decision` tables (dkFn with isDecision), which are
# whole functions that ARE a table — those are skipped outright.
#
# THIS PASS DOES NOT FAIL FAST — and that is deliberate, against the grain of
# every other stage in this compiler.
#
# Elsewhere, stopping at the first error is right: a type error makes every
# later type meaningless, so reporting fifty cascading consequences of one
# mistake helps nobody. Size is not like that. Each function's numbers are
# INDEPENDENT — one oversized fn tells you nothing about the next — so the
# whole program can be measured before anything is decided, and the useful
# output is the RANKED LIST. "These are your five worst functions, worst
# first" is a work plan. "Function `client` is 14 lines" is a nag that hides
# the 22-line one behind it.
#
# So the pass MEASURES and returns; the DRIVER decides what a violation means.
# That split is what lets the same numbers be a hard error in a release build
# and a report in a normal one, without the pass knowing which build it is in.
import ast, strutils, algorithm
import diagnostics

type
  Budget* = object
    ## Zero on either field disables that check — how `--max-complexity:0` and
    ## `--max-fn-lines:0` opt out without a separate "enabled" flag.
    maxComplexity*: int
    maxLines*: int

  Offender* = object
    ## One function over at least one limit. Carries BOTH numbers, not just the
    ## one that tripped: a fn at complexity 9 AND 30 lines is a different job
    ## from one at complexity 9 and 8 lines, and the reader wants to see that
    ## without re-running under other flags.
    name*: string
    complexity*: int
    lines*: int
    overComplexity*: bool
    overLines*: bool
    span*: Span

const
  DefaultMaxComplexity* = 6
  DefaultMaxLines* = 8

var sizeBudget* = Budget(maxComplexity: DefaultMaxComplexity,
                         maxLines: DefaultMaxLines)
  ## The active limits, set from `--max-complexity:N` / `--max-fn-lines:N`.
  ## A module-level var for the same reason modules.projectRoot is one: it is a
  ## build-wide setting read deep in a pass, and threading it through every
  ## call between the driver and here would buy nothing.

var sizeIsError* = false
  ## Whether being over budget FAILS the build, or merely reports.
  ##
  ## Set by `--release`. The rationale is that the two builds are used at
  ## different moments: a normal build is the inner loop, where a half-written
  ## fn is temporarily long ON PURPOSE and a hard stop would be in the way. A
  ## release build is the moment you ship, which is exactly when "I will split
  ## it later" needs to stop being an option.
  ##
  ## Same measurement either way — only the consequence changes. That is the
  ## point of the pass returning offenders rather than raising: it does not
  ## need to know which build it is in.

type
  Metrics = object
    complexity: int   # branch points; the +1 base is added by the caller
    minLine: int      # 0 = nothing seen yet
    maxLine: int

proc note(m: var Metrics, span: Span) =
  ## Widen the line extent to include `span`. Line 0 means the node was built
  ## by a later pass rather than parsed, so it marks no source position.
  if span.line <= 0: return
  if m.minLine == 0 or span.line < m.minLine: m.minLine = span.line
  if span.line > m.maxLine: m.maxLine = span.line

proc walk(m: var Metrics, e: Expr)

proc walkTabular(m: var Metrics, body: Expr) =
  ## An arm body of a match/select. Walked for complexity, but its lines do not
  ## widen the enclosing extent — see the TABULAR EXEMPTION note above.
  if body == nil: return
  var inner = Metrics(complexity: 0, minLine: 0, maxLine: 0)
  walk(inner, body)
  m.complexity += inner.complexity

proc walkMatch(m: var Metrics, e: Expr) =
  ## The construct itself costs NOTHING — not +1 per arm, not even +1 total.
  ## Arm bodies ARE measured; it is only the tabulation that is free.
  walk(m, e.subject)
  for arm in e.arms:
    # A guard IS branching logic — it is a condition, not a table row.
    if arm.guard != nil:
      m.complexity += 1
      walkTabular(m, arm.guard)
    walkTabular(m, arm.body)

proc walkSelect(m: var Metrics, e: Expr) =
  for arm in e.selArms:
    walkTabular(m, arm.arg)
    walkTabular(m, arm.body)

proc walk(m: var Metrics, e: Expr) =
  if e == nil: return
  m.note(e.span)
  case e.kind
  of exkIf:
    # `if` forks; a bare `else` does not (it is the path already counted).
    m.complexity += 1
    walk(m, e.cond)
    walk(m, e.thenBranch)
    walk(m, e.elseBranch)
  of exkWhile:
    m.complexity += 1
    walk(m, e.whileCond)
    walk(m, e.whileBody)
  of exkFor:
    m.complexity += 1
    walk(m, e.iterable)
    walk(m, e.body)
  of exkMatch: walkMatch(m, e)
  of exkSelect: walkSelect(m, e)
  of exkBinary:
    # Short-circuit operators fork: `a and b` may or may not evaluate b.
    # Arithmetic and comparison do not.
    if e.binOp in {boAnd, boOr}: m.complexity += 1
    walk(m, e.left)
    walk(m, e.right)
  of exkUnary:
    # `expr?` propagates an error upward — an implicit early return, so it is
    # a fork in the flow exactly like an `if err: return err` would be.
    if e.unaryOp == uoPropagate: m.complexity += 1
    walk(m, e.operand)
  of exkBlock:
    for s in e.stmts: walk(m, s)
  of exkCall:
    walk(m, e.callee)
    for a in e.args: walk(m, a)
  of exkChain:
    walk(m, e.base)
    for step in e.steps:
      m.note(step.span)
      walk(m, step.target)
      walk(m, step.arg)
  of exkStruct:
    for f in e.fields: walk(m, f.value)
  of exkList:
    for item in e.items: walk(m, item)
  of exkBracket:
    walk(m, e.brReceiver)
    for a in e.brArgs: walk(m, a)
  of exkBracketAssign:
    walk(m, e.brTarget)
    walk(m, e.brValue)
  of exkAssign:
    walk(m, e.target)
    walk(m, e.assignVal)
  of exkField:
    walk(m, e.receiver)
    walk(m, e.dotArg)
  of exkReturn:
    walk(m, e.returnVal)
  of exkRaise:
    walk(m, e.raiseVal)
  of exkSend:
    walk(m, e.sendPayload)
  of exkLit, exkVar, exkQualified, exkBreak, exkContinue, exkImport:
    discard

proc measure(body: Expr): tuple[complexity, lines: int] =
  ## McCabe starts at 1: a body with no forks still has one path through it.
  var m = Metrics(complexity: 0, minLine: 0, maxLine: 0)
  walk(m, body)
  let lines = if m.minLine == 0: 0 else: m.maxLine - m.minLine + 1
  (m.complexity + 1, lines)

proc checkFn(acc: var seq[Offender], name: string, body: Expr, span: Span,
             b: Budget) =
  if body == nil: return  # `pending:` and extern sigs have no body to measure
  let (complexity, lines) = measure(body)
  let overC = b.maxComplexity > 0 and complexity > b.maxComplexity
  let overL = b.maxLines > 0 and lines > b.maxLines
  if overC or overL:
    acc.add(Offender(name: name, complexity: complexity, lines: lines,
                     overComplexity: overC, overLines: overL, span: span))

proc verifyDecl(acc: var seq[Offender], d: Decl, b: Budget) =
  if d == nil: return
  case d.kind
  of dkFn:
    # A `decision` table IS a table — the whole fn is rows, exempt for the
    # same reason match arms are.
    if not d.isDecision: acc.checkFn(d.name, d.fnBody, d.span, b)
  of dkTask:
    acc.checkFn(d.name, d.taskBody, d.span, b)
  of dkActor:
    for h in d.handlers: acc.verifyDecl(h, b)
  of dkMixin, dkExtern, dkPending:
    for mem in d.mixinMembers: acc.verifyDecl(mem, b)
  of dkWhen:
    for inner in d.whenDecls: acc.verifyDecl(inner, b)
  else:
    # ONLY FUNCTIONS HAVE A SIZE BUDGET. A type, enum, interface, decision
    # table or const is a DECLARATION — it has no paths through it and no
    # body to split, so neither number means anything there. A 40-variant sum
    # type is a vocabulary, not a long function, and pressuring an author to
    # shorten it would be pressuring them to describe their domain in less
    # detail. Everything not measured above is deliberately exempt.
    discard

proc overBudgetBy(o: Offender, b: Budget): int =
  ## How far over the line this fn is, as ONE number, so the two limits can be
  ## ranked against each other. Each limit contributes its own overshoot, which
  ## makes a fn that breaks both sort above one that breaks either — which is
  ## what "worst first" should mean when the two are not comparable units.
  if o.overComplexity: result += o.complexity - b.maxComplexity
  if o.overLines: result += o.lines - b.maxLines

proc measureModule*(m: Module, b: Budget): seq[Offender] =
  ## Every function over either limit, WORST FIRST. Measures the whole module
  ## before returning — see the no-fail-fast note at the top of this file.
  ##
  ## Runs after typecheck so a badly-typed file reports its type error first: a
  ## size report on code that does not compile is noise.
  if b.maxComplexity <= 0 and b.maxLines <= 0: return
  for d in m.decls: result.verifyDecl(d, b)
  # Ties broken by source order, so the list is stable between runs rather than
  # reshuffling on an unrelated edit.
  result.sort(proc (x, y: Offender): int =
    result = cmp(y.overBudgetBy(b), x.overBudgetBy(b))
    if result == 0: result = cmp(x.span.line, y.span.line))

proc describe*(o: Offender, b: Budget): string =
  ## One offender as a report line. Names only the limits it actually broke,
  ## but always shows both numbers.
  ##
  ## The code is spelled `[TK-CX01]` WITHOUT the "Complexity Error" prefix that
  ## withCode would add. This pass is the first whose severity varies — the
  ## same line is a note on a normal build and a failure under --release — so
  ## calling it an "Error" while it is not failing anything would be a lie in
  ## the common case. The code itself is unchanged, so `tuck explain` and
  ## grepping both still work.
  var parts: seq[string]
  if o.overComplexity:
    parts.add("cyclomatic complexity " & $o.complexity & " (limit " &
              $b.maxComplexity & ")")
  if o.overLines:
    parts.add("spans " & $o.lines & " lines (limit " & $b.maxLines & ")")
  let dc = if o.overComplexity: dcCxComplexity else: dcCxLines
  "[" & $dc & "] fn '" & o.name & "' " & parts.join(", ")
