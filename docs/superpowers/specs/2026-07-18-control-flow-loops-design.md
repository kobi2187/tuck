# Control Flow: Unified `for`, `loop`, break/continue, `fn inline`

## Context

Tuck had only `for pat in iterable:` — no `while`, no infinite-loop form, no
`break`/`continue` at all (checked: no tokens, no AST nodes exist today), and
no indexed iteration. This is a real gap for embedded targets (poll loops,
retry loops, buffer fills) where these are everyday primitives.

Odin's unified `for` (one keyword, form determined by what follows it) was
the stated inspiration. The design keeps that unification while fitting
Tuck's existing colon+indent grammar and its stated philosophy: no labels,
no goto-shaped control flow, structure over jumps (same stance as the
cyclomatic-complexity limit and the no-preprocessor rule already in the
spec). A `fn inline` mechanism is added alongside so the "extract nested
logic into a helper fn instead of labeled break" pattern costs nothing at
codegen time on embedded targets.

## Forms

```tuck
loop:                        # infinite (while-true)
  poll()
  if done(): break

for ready():                 # while-style — cond directly after for, no `in`
  tick()

for i in 0 .. 10:             # inclusive range, i = 0..10
  ...

for i in 0 ..< 10:            # exclusive range, i = 0..9
  ...

for item in items:           # iterate values (existing)
  ...

for idx, item in items:      # iterate with index (new)
  ...
```

`break` and `continue` affect the nearest enclosing loop. No labels, ever —
matches every mainstream language's unlabeled form, still fully structured
since neither can cross a function boundary or jump anywhere but loop
start/end.

**No C-style 3-clause `for`.** Odin's own docs note range-for + while-for
cover it; a post-step is just the last statement in the loop body. Skipping
it avoids introducing `;` as a new separator token used nowhere else in the
grammar.

**No labeled break/continue.** Multi-level early exit is deliberately
*not* a loop-level control-flow feature — it's a decomposition signal.
Extract the inner loop into its own function; it returns a value or raises,
the outer loop reacts via the return. This is consistent with the spec's
existing cyclomatic-complexity ceiling (≤5) and "no preprocessor soup"
stance: nested-break-through-two-loops is exactly the kind of thing that
should become a named function.

## Range operator

`..` already exists as the tight chain-mutator token (`s ..port {host: 80}`,
no space, always followed directly by a field name). Ranges reuse `..` but
require surrounding spaces (`0 .. 10`), which is how the lexer/parser tells
the two apart — the mutator form is never spaced, the range form always is.

Inclusive/exclusive spelling follows Nim (the compile target), for mental-
model consistency between Tuck source and the Nim it lowers to:
- `0 .. 10` — inclusive
- `0 ..< 10` — exclusive

## `for idx, item in items:` — grammar

`Pattern` already has a `pkTuple` kind (`elems: seq[Pattern]`) used today
only inside decision-table row-matching. The `for` parse site gets bare
comma-pattern handling added locally (parse one pattern, check for `,`,
parse a second, wrap `pkTuple`) rather than teaching general `parsePattern`
to consume top-level commas — keeps match-arm parsing elsewhere unaffected.

## `fn inline`

New optional keyword slot right after `fn`, before the function name:

```tuck
fn inline queuePush({msg: Msg}) -> !void [no_alloc, irq_safe]:
  ...
```

This is *not* an effect marker (§3.7's `[io, irq_safe, ...]` bracket is a
checker-enforced propagating contract) and *not* a purity prefix (§3.6's
`pred`/`set`, which replace `fn` and are mutually exclusive with each
other). `inline` is a third, orthogonal thing — a codegen/layout hint, same
category as a type's `[packed, align: N]` but scoped to a function. A
bracket was considered and rejected: mixing it into the effect-marker
bracket conflates two different categories (propagating checker contracts
vs. non-propagating codegen hints); a second bracket was rejected as too
visually heavy for what's expected to stay a small, rarely-multiple set. A
bare sigil (`fn %queuePush`) was also considered and rejected because it
doesn't scale past exactly one attribute — a plain keyword slot does, at
the cost of nothing (each future attribute like `cold` is just one more
recognized keyword in that position, no new grammar shape).

Compiles to Nim's `{.inline.}` pragma. Exists specifically so the "no
labels — decompose into a fn instead" story above has no runtime cost on
embedded targets: extracting a hot inner loop into its own function and
marking it `inline` should produce codegen indistinguishable from having
written it inline by hand.

## Non-goals / explicitly deferred

- Labeled break/continue — rejected outright, not deferred; see above.
- C-style 3-clause for — rejected outright.
- Further fn-level codegen attributes (`cold`, `noinline`, etc.) — the
  keyword-slot mechanism supports them later; none are being added now.

## Verification

- Parser: new tokens/grammar (`loop`, bare `for cond:`, spaced `..`/`..<`
  range operator, comma pattern in `for`, `break`, `continue`, `inline`
  keyword after `fn`) get parser unit tests alongside existing ones in
  `tests/typecheck_tests.nim`'s parser coverage or a new
  `tests/parser_loops_tests.nim`.
- Codegen: each new AST form emits valid Nim (both `genExpr` overloads,
  per the standing gotcha) and valid Beef; add to
  `tests/compile_all_examples.nim` / `tests/beef_backend.nim` gates once an
  example exercises them.
- Runtime: a `cli_smoke.sh` case that actually runs a compiled binary using
  `loop: / break`, a `while`-style `for cond:`, and `for idx, item in items:`
  and asserts on the exit code — matches this project's standing pattern of
  runtime-verifying every new feature, not just checker-green.
- `fn inline`: confirm emitted Nim carries `{.inline.}` and (for Beef) its
  equivalent; no runtime-observable test needed beyond a compile check
  since it's a codegen hint with no semantic effect.
