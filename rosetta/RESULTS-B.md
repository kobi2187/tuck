# Batch B — Control flow / logic — results

25 files, `rosetta/examples/b01-*.tuck` .. `b25-*.tuck`.

**Correction (this pass):** my earlier draft claimed `for cond:` CHECKS but
never builds, "3/3 files, undeclared identifier: 'cond'". That was wrong —
I had literally written the doc metavariable `cond` as an identifier in
b11/b13/b14 instead of a real condition. Once fixed to real conditions
(`for bottles > 0:`, `for n > 0:`, `for total <= threshold:`) all three
build and run correctly. **The while-style loop form itself is not broken.**
b06's build failure is real but unrelated (int `/` promotes to float — see
below). Team lead independently verified `for n > 0:` builds/runs GREEN.
Standard applied from here on: every claim below is either a status directly
observed from `tuck check`/`tuck build`/running the binary, or explicitly
marked otherwise.

**Second correction (this pass):** my first "Proposed stdlib API" writeup
claimed b21 (`min`/`max`/`clamp`) and b25 (`abs`/`sign`) both "ran and
printed correct output through the pending stubs." Re-checked against
DISCOVERIES.md's separately-confirmed bug (#11, Nim builtin shadowing) by
diffing each program's stdout against whether its `TUCK PENDING: <name>
invoked` stderr line actually fired. Also wrote and ran an isolated
single-fn repro, `rosetta/examples/b21b-clamp-only.tuck`, to settle `clamp`
specifically.
- b21: `min` and `max` never printed a PENDING line — Nim's own builtin
  `min`/`max` silently intercepted the declared stub. `clamp` **also**
  never printed a PENDING line, confirmed independently via the b21b
  isolated repro (`{value: 137, low: 0, high: 100} clamp` → prints `100`
  with zero PENDING output) — Nim has `clamp` in `system`/`std/math` too.
  All three of b21's invented fns were silently shadowed.
- b25: `sign` correctly fired its PENDING line (prints 0, the stub
  default) — genuine stub execution. `abs` never fired a PENDING line —
  also a Nim builtin, also silently shadowed; the `14` printed is Nim's
  real `abs`, not evidence my `pending:` fn works.

Net result: of my 5 "invented stdlib fn" files, only `parseInt` (b22),
`randomBool` (b24), and `sign` (b25) genuinely exercised the `pending:`
path (confirmed by the PENDING stderr line firing). `min`, `max`, `clamp`,
and `abs` were all silently captured by Nim's `system` module — this is
DISCOVERIES.md bug #11, and it means naming a stdlib candidate the same as
a common word is actively dangerous for this kind of survey, not just for
real programs: every one of those four names looked like it "worked" until
checked against the PENDING marker.

| file | task | status | detail |
|---|---|---|---|
| b01-loop-range | loop over a range | GREEN | prints 1..5 |
| b02-nested-loops | nested loops | GREEN | prints 3x3 multiplication grid |
| b03-loop-break | loop with break | GREEN | prints 8 |
| b04-loop-continue | loop with continue | GREEN | prints 30 (sum of evens 1-10) |
| b05-infinite-loop-guard | infinite `loop:` + guarded break | GREEN | prints 32 |
| b06-while-style | while-style loop, Collatz step count | CHECKS | `tuck check` OK. Build fails: `n / 2` on `int` `n` infers Nim `float`, then reassigning to the `int` var is a type mismatch: `b06_while_style.nim(12, 17) Error: type mismatch: got 'float' for 'n / 2' but expected 'int'`. This is the KNOWN integer-division bug (DISCOVERIES.md #12: `/` always emits Nim float `/`), not a loop-form problem. |
| b07-boolean-values | boolean values | GREEN | prints "ready" / "not done" |
| b08-logical-operations | `and`/`or`/`not` | GREEN | prints "not both" / "at least one" / "b is false" |
| b09-ternary-choice | ternary-style choice via if/else into a var | GREEN | prints "odd" (no `if` expression exists, so this if/else-assign is the natural idiom) |
| b10-conditional-structures | grade a score, natural `elif` chain | PARSE | `Expected expression but got: tkElif` at `elif score >= 80:`. `elif` is lexed but not parsed. |
| b11-99-bottles | countdown loop, while-style | GREEN | prints 3,2,1,"no more bottles". (Originally miswritten as literal `for cond:` — fixed to `for bottles > 0:`, a real condition, and reverified.) |
| b12-100-doors | 100 doors puzzle, nested loops + toggle + `xs[i]` | GREEN | opens doors 1, 4, 9 (perfect squares) — correct |
| b13-countdown | countdown from 5, while-style | GREEN | prints 5,4,3,2,1,"liftoff". (Same fix as b11: `for n > 0:`.) |
| b14-sum-until-threshold | sum 1+2+3+... until > threshold, while-style | GREEN | prints 55. (Same fix as b11: `for total <= threshold:`.) |
| b15-early-return | early return from a function | GREEN | prints 7 (first divisor of 91) |
| b16-guard-clauses | guard clauses, natural `elif` | PARSE | Same as b10: `Expected expression but got: tkElif` at `elif n == 0:`. |
| b17-decision-table | `decision` table on a sum-type value | CHECKS | `tuck check` OK. Build fails: `attempting to call routine: 'High'` — payload-less sum-type variant `{} High` used as a value. Same root cause as DISCOVERIES.md bug #2 (payload-less variant construction emits a bare-enum call, not a constructor). |
| b18-match-bool | match on a bool value, both arms + no catch-all | PARSE | `tuck check` fails (type error): `match is not exhaustive — missing true, false` even though both `true:`/`false:` arms are present. Matches DISCOVERIES.md bug #4 exactly. |
| b19-match-catchall | match with a catch-all `_` arm | CHECKS | `tuck check` OK. Build fails: `the special identifier '_' is ignored in declarations and cannot be used`. Matches DISCOVERIES.md bug #3. |
| b20-state-check-match | match on a 3-variant sum type | CHECKS | `tuck check` OK. Build fails: `attempting to call routine: 'Green'` on payload-less variant construction — same as b17 / bug #2. |
| b21-clamp-and-minmax | clamp + min/max, invented fns | MIXED | Declared `min`, `max`, `clamp` in `pending:`. Checks and builds. Runtime: **none of the three ever printed a `TUCK PENDING` line — all silently shadowed by Nim's builtins `min`/`max`/`clamp`** (DISCOVERIES.md bug #11), confirmed for `clamp` specifically via an isolated single-fn repro (`b21b-clamp-only.tuck`). Do not read this file's stdout as evidence any of the three fns "work" — it's evidence of the shadowing bug, not of my proposed API. |
| b22-decision-with-parsed-input | branch on a parsed string, invented `parseInt` | NEEDS/GREEN | Declared `parseInt` in `pending:`. Builds and runs; `TUCK PENDING: parseInt invoked` correctly fires (not a Nim builtin name), confirming the stub path genuinely ran. Stub returns 0, so "even" branch is coincidentally right — a real implementation is needed before trusting this program's logic. |
| b23-loop-building-string | build a "stars" string per loop iteration, invented `repeated` | NEEDS/CHECKS | Declared `repeated({text: str, times: int}) -> str` in `pending:`. `tuck check` OK. Build fails: `Expected one of: proc repeated[T](payload: T): string — extra argument given`. This matches DISCOVERIES.md bug #7 exactly (`pending:` stub arity mismatch for 2+ field payloads) — independently confirmed, not a new finding. |
| b24-random-guard | loop-with-guard driven by invented `randomBool` | NEEDS/GREEN | Declared `randomBool({}) -> bool` in `pending:`. Builds and runs; `TUCK PENDING: randomBool invoked` correctly fires every iteration (not a Nim builtin name), confirming genuine stub execution. **Authoring note, not a compiler bug:** first draft used unbounded `loop: ... if {} randomBool: break`; since the stub deterministically returns `false`, this never terminates (had to kill a runaway process that had produced >5GB of stderr). Rewrote with `for flips < 1000:` as an explicit bound — bounded loop confirmed to terminate cleanly at 1000 iterations. |
| b25-abs-and-sign | abs + sign, invented fns | MIXED | Declared `abs`, `sign` in `pending:`. Builds and runs. `sign` correctly fires its PENDING line (prints 0, the stub default) — genuine stub execution. **`abs` never fires a PENDING line — silently shadowed by Nim's builtin `abs`** (same bug #11 as b21's min/max). The printed `14` is Nim's real abs, not evidence my declared stub works. |

## Language-syntax findings (NOT stdlib — these are compiler/parser/checker/codegen gaps)

All independently cross-checked against DISCOVERIES.md's minimal-repro list
(the shared, verified findings file). Nothing below is a "batch B only"
claim now — each maps to a numbered item there.

1. **No `elif`.** PARSE error, hit twice (b10, b16) in ordinary code —
   grading bands and guard-clause chains are exactly where `elif` is
   idiomatic. Forces nested if/else pyramids or `match`.
2. **`match` on `bool` fails exhaustiveness** even with both arms present
   (b18) = DISCOVERIES.md #4.
3. **`match` with `_` catch-all CHECKS but fails to build** (b19) =
   DISCOVERIES.md #3.
4. **Payload-less sum-type variant construction `{} Name` breaks codegen**
   (b17, b20) = DISCOVERIES.md #2.
5. **Int division silently promotes to float** (b06) = DISCOVERIES.md #12.

These are compiler/parser bugs; fixing the stdlib will not fix any of them.

## Proposed stdlib API

Ranked by how many of the 25 examples wanted the function, with the caveat
above applied: only entries whose `pending:` stub was CONFIRMED to actually
execute (PENDING line fired) count as "genuinely demonstrated." `min`,
`max`, `abs` are marked accordingly — their need is still real (any Tuck
program obviously wants abs/min/max), but this batch did not actually prove
the `pending:` mechanism works for them, because Nim's `system` module ate
the calls first (DISCOVERIES.md #11).

### Arithmetic helpers

```tuck
fn abs({n: int}) -> int
```
Wanted by: b25. **Caveat: b25's run did not genuinely exercise this stub**
(Nim builtin shadowing, bug #11) — the need for `abs` is still obviously
real (every abs-value / distance / magnitude task wants it, and there's no
`if`-expression to hand-roll it inline), but this file doesn't prove the
compiler handles it once implemented; it proves the *opposite*, that a
same-named Tuck fn is currently invisible.

```tuck
fn sign({n: int}) -> int
```
Wanted by: b25. **Confirmed via genuine stub execution** (PENDING line
fired). Returns -1/0/1; pairs naturally with `abs`.

```tuck
fn min({a: int, b: int}) -> int
fn max({a: int, b: int}) -> int
```
Wanted by: b21. **Caveat: same shadowing issue as `abs`** — did not
genuinely exercise the stub. Still an obviously-wanted pair (most
reached-for functions in any language), but implementing them under these
exact names will need the shadowing bug (#11) fixed first, or they will
silently do the wrong thing (or the right thing by coincidence) forever.

```tuck
fn clamp({value: int, low: int, high: int}) -> int
```
Wanted by: b21. **Caveat: same shadowing issue** — `clamp` is also a Nim
builtin (`system`/`std/math`); confirmed via an isolated single-fn repro
(`b21b-clamp-only.tuck`) that it never fires its PENDING line either.
Bounding a value into a range is still common and fiddly to hand-roll
correctly with nested if/else — the need stands, the evidence for the
stub mechanism does not.

### String manipulation

```tuck
fn parseInt({text: str}) -> int
```
Wanted by: b22. **Confirmed via genuine stub execution.** Turning input
text into a number is foundational for any program branching on external
data — matches DISCOVERIES.md's independently-flagged "no int-parsing from
str" gap.

```tuck
fn repeated({text: str, times: int}) -> str
```
Wanted by: b23. Never got to run — blocked by the `pending:` arity bug
(DISCOVERIES.md #7), confirmed here independently. Still clearly wanted:
building a string by repetition is the natural workaround for no growable
sequences (bar charts, indentation, separators, ASCII art).

### Randomness

```tuck
fn randomBool({}) -> bool
```
Wanted by: b24. **Confirmed via genuine stub execution** (PENDING line
fired every iteration). Needed for coin-flip / dice / retry-jitter style
control flow. Its absence is also an active footgun independent of "is it
in the stdlib": a `pending:` bool stub defaults to `false`, so any
"loop until random condition" example silently becomes an infinite loop
unless the author adds an explicit bound (had to kill a runaway process
while writing b24 for exactly this reason).

## Summary

- GREEN (builds + runs, output verified against source logic): **15** —
  b01, b02, b03, b04, b05, b07, b08, b09, b11, b12, b13, b14, b15, b22, b24
- MIXED (builds + runs, but stdout does not reliably reflect the declared
  `pending:` fn due to Nim-builtin shadowing): **2** — b21, b25
- CHECKS (check OK, build fails): **4** — b06, b17, b19, b20
- NEEDS/CHECKS (check OK, build fails on the `pending:` arity bug): **1** —
  b23
- PARSE (parser/typechecker rejects): **3** — b10, b16 (both `elif`), b18
  (match exhaustiveness on bool)

Every finding above was reduced to a specific file, a specific `tuck
check`/`tuck build` error, and (where applicable) actual stdout/stderr from
running the binary — no claim in this version rests on assumption. The
`for cond:` claim from the previous draft is retracted in full: it was an
authoring mistake, not a compiler bug, confirmed independently by both this
agent and the team lead.

Language-syntax gaps (elif, bool-match exhaustiveness, `_` catch-all
codegen, sum-type-variant-as-value codegen, int-division-to-float) are
compiler/parser/checker bugs, not stdlib gaps — listed separately above.

Proposed stdlib, by genuinely-confirmed demand: `sign`, `parseInt`,
`randomBool` (stub execution confirmed working — PENDING line fired);
`repeated` (need confirmed, but blocked from running by the arity bug,
DISCOVERIES.md #7); `abs`, `min`, `max`, `clamp` (need is obvious but
this batch's evidence for all four is compromised by Nim-builtin
shadowing, DISCOVERIES.md #11, confirmed via both the combined runs and
an isolated single-fn repro for `clamp` — worth re-testing once bug #11
is fixed, under names that don't collide with `system`).
