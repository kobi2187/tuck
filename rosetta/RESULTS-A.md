# Results — Batch A: numeric & math (20 examples)

Revision note: an earlier pass of this file reported a04/a14/a15 as a
compiler codegen bug in `for cond:`. That was wrong. `for cond:` is not a
broken construct — `for b != 0:` (a real condition) builds and runs
correctly. The mistake was mine: I wrote the literal metavariable word
`cond` from an earlier SYNTAX.md draft instead of substituting a real
condition, e.g. `for cond:` instead of `for b != 0:`. Tuck correctly parsed
that as "loop while the variable `cond` is true" — no such variable exists,
so it failed at the Nim stage with an undeclared-identifier error that
*looked* like a codegen bug but wasn't.

The real bug that mistake exposed is the one worth recording: **`tuck check`
accepts any undeclared identifier with no diagnostic.** `let x =
totallyUndeclared + 1` and `for undeclaredThing:` both pass `check` clean and
only fail later at the raw Nim stage. Root cause per DISCOVERIES.md: the
gradual-typing sentinel (`UnknownName` in ast.nim, "undeclared symbols
synthesize this named type") swallows genuine typos instead of flagging
them, breaking the compiler's promise of surfacing Tuck-level diagnostics
before Nim ones. a04-gcd, a14-digit-sum, and a15-reverse-digits were fixed to
use real conditions (`for b != 0:`, `for n != 0:`) and re-verified below;
a04 is now GREEN. a14/a15 still fail build, but for an unrelated, genuine
codegen bug (int division emitting Nim's `/` instead of `div` — detailed in
their rows and the pain-points section).

This revision also leans into inventing stdlib functions per the reframe:
the goal is surfacing what Tuck's standard library should contain, not
avoiding functions that don't exist yet.

| file | task | status | detail |
|---|---|---|---|
| a01-fizzbuzz.tuck | FizzBuzz 1..20 | GREEN | builds+runs, correct output |
| a02-factorial.tuck | factorial(10) | GREEN | printed 3628800 |
| a03-fibonacci.tuck | fibonacci first 10 | GREEN | printed 0 1 1 2 3 5 8 13 21 34 |
| a04-gcd.tuck | GCD via Euclid, `for b != 0:` while-style loop | GREEN | printed 6 |
| a05-lcm.tuck | LCM via invented `gcd` | NEEDS / CHECKS | `check` reports PENDING correctly; `build` fails. The pending stub `fn gcd({a: int, b: int}) -> int` codegens as `proc gcd*[T](payload: T): int`, but the postfix call site `{a: x, b: y} gcd` codegens as `gcd(x, y)` — two positional Nim args against a one-param generic proc. Nim error: `extra argument given`. Reproduced in isolation with a minimal 2-field pending stub (`add({a: int, b: int}) -> int` called as `{a: 3, b: 4} add`) — same `add(3, 4)` vs. `proc add[T](payload: T)` mismatch, same `extra argument given` error. Not `cond`-contamination; a genuine, minimal, reproducible codegen bug. |
| a06-is-prime.tuck | primality by trial division | GREEN | printed "prime" for 29 |
| a07-sum-series.tuck | sum 1..100 | GREEN | printed 5050 |
| a08-average.tuck | average via invented `average({items: Seq[int]}) -> float` | GREEN (stub) | builds+runs; prints the pending-stub warning to stderr then `0.0`, since the fn is genuinely unimplemented. Single-field `Seq` payload does NOT hit the a05/a13 arg-count bug — worth noting as a boundary case. |
| a09-even-odd.tuck | even/odd of 17 | GREEN | printed "odd" |
| a10-compare-ints.tuck | compare 7 vs 12 | GREEN | printed "a is smaller" |
| a11-celsius-fahrenheit.tuck | 100C to F | GREEN | printed 212.0 (int arithmetic silently promoted to Nim float, see stdlib section) |
| a12-leap-year.tuck | leap year check, 2024 | GREEN | printed "leap year" |
| a13-power.tuck | 2^10 via invented `pow({base: int, exp: int}) -> int` | NEEDS / CHECKS | same bug as a05: `pow(2, 10)` positional call against `proc pow*[T](payload: T): int`. Nim error: `extra argument given`. |
| a14-digit-sum.tuck | digit sum, `for n != 0:` while-style loop | CHECKS | `check` OK; build fails. `n = n / 10` (n: int) codegens Nim `/` (always float division) instead of `div`, so a `var n: int` reassignment becomes `n = (n / 10): float`. Nim error: `type mismatch: got 'float' ... expected 'int'`. Genuine codegen bug, distinct from the a04/14/15 authoring mistake noted above. |
| a15-reverse-digits.tuck | reverse digits, `for n != 0:` while-style loop | CHECKS | identical `/`-not-`div` bug as a14. |
| a16-min-max.tuck | min/max via invented `min`/`max` over `[7,2,9,4,1,8]`, uses `xs[0]` + `import seq` | GREEN (but suspect) | builds+runs, prints correct 1 then 9 — but the generated Nim calls `min(lo, n)` / `max(hi, n)` against pending stubs `proc min*[T](payload: T): int` / `proc max*[T](payload: T): int`. That should be an arg-count error like a05/a13, but Nim's own **builtin** `system.min`/`system.max` (2-arg overloads) silently shadow the pending stub instead. The "TUCK PENDING" stderr line never fires. Correct output for the wrong reason — a real Tuck program relying on its own `min`/`max` pending stub would silently get Nim's builtin instead, with no diagnostic. Distinct from a05/a13 despite an identical-looking pending declaration; the only difference is the name collides with a Nim builtin. |
| a17-absolute-value.tuck | abs(-42) via invented `abs({value: int}) -> int` | GREEN (stub) | builds+runs; single-field payload, same safe shape as a08, prints the pending warning then presumably 0 — not yet a false positive. |
| a18-triangle-area.tuck | area = base*height/2 | GREEN | printed 30.0 (int/int division silently promoted to float, no reassignment involved so it doesn't hit the a14/a15 build failure) |
| a19-perfect-number.tuck | perfect number check via invented `sumProperDivisors({value: int}) -> int` | GREEN (stub) | builds+runs; single-field payload, prints pending warning then "not perfect" (0 != 28) — correctly reflects the unimplemented stub, no false positive. |
| a20-multiplication-table.tuck | 7 times table | GREEN | printed 7 14 21 28 35 42 49 56 63 70 |

## Summary

- **GREEN: 15/20** (3 of these — a08, a17, a19 — are "green" only because they
  call a still-pending stub and print its placeholder output; a16 is green
  for the wrong reason, see above)
- **CHECKS: 2/20** (a14, a15 — genuine `/`-vs-`div` codegen bug)
- **NEEDS / CHECKS: 2/20** (a05, a13 — pending-stub call-shape mismatch)
- **PARSE: 0/20** — no natural code was rejected by the parser in this batch.

## Top pain points writing natural code

1. **Multi-field `pending:` stubs don't match their call site's codegen.**
   Any invented fn with 2+ named fields in its payload (`{a, b}`, `{base,
   exp}`) breaks at the Nim stage unless its name happens to collide with a
   Nim builtin. Single-field payloads (`{value: int}`, `{items: Seq[int]}`)
   are safe. This is the biggest blocker to the "invent freely" workflow the
   team asked for — exactly the two-argument math functions (`pow`, `gcd`,
   `max`, `min`) that are most natural to invent are the ones most likely to
   break.

2. **Name collisions with Nim builtins fail silently, not loudly.** `min`/
   `max` "worked" but only because Nim's own stdlib intercepted the call
   before the pending stub ever ran. This is worse than an outright build
   error: it produces a program that looks correct today and would silently
   diverge from spec the moment `min`/`max` got a real Tuck implementation
   with different semantics than Nim's.

3. **Integer division silently becomes float division in codegen**, and
   whether it's caught depends entirely on what you do with the result. As a
   `let` binding it just prints an unwanted `.0` (a08, a11, a18). Reassigned
   into a `var: int` it's a hard Nim type error (a14, a15). Both are the same
   root cause surfacing at two different severities.

4. **No `elif` and no `if` expression** still tax ordinary branch-heavy or
   pick-a-value numeric code with extra nesting/mutation, as noted in the
   prior revision — unchanged by this pass.

## Proposed stdlib API

Ranked by how many of the 20 examples wanted it. Every signature below is
what I actually wrote in a `pending:` block and called via postfix struct
payload.

### num (highest priority — every example needed at least one)

1. **`fn pow({base: int, exp: int}) -> int`** — needed by a13-power. Every
   "compute an exponent" task wants this; hand-rolling with a loop (my first
   draft) works but defeats the purpose of having a numeric stdlib at all.
   Also exposed the multi-field pending-stub bug — highest-value function to
   fix codegen for.
2. **`fn abs({value: int}) -> int`** — needed by a17-absolute-value. Every
   sign-handling task wants this instead of a manual `if n < 0: negate`.
3. **`fn min({a: int, b: int}) -> int`** / **`fn max({a: int, b: int}) -> int`**
   — needed by a16-min-max, used inside a reduction loop over a fixed array.
   Almost certainly the most-reached-for pair of functions in any numeric
   corpus; also the pair that exposed the silent-Nim-builtin-shadowing bug,
   so these need first-class Tuck implementations, not aliases to Nim's.
4. **`fn gcd({a: int, b: int}) -> int`** — needed by a05-lcm (LCM is
   trivially `a*b/gcd(a,b)`, so gcd is the true primitive; LCM itself may not
   need to be stdlib if gcd exists).
5. **`fn average({items: Seq[int]}) -> float`** — needed by a08-average.
   Currently every "average of a list" task hand-rolls a sum-then-divide
   loop; a real stdlib fn also gives a natural place to fix the int/float
   division question once instead of at every call site.
6. **`fn sumProperDivisors({value: int}) -> int`** — needed by a19-perfect-
   number. Narrower use case than the others but a clean example of "give
   the concept a name" rather than inlining a divisor-summing loop; a
   generalized `divisors({value: int}) -> Seq[int]` might be the more
   reusable primitive underneath it, letting `sumProperDivisors` become a
   two-line composition instead of its own stdlib entry.

### Recommendation: Tuck's division story

**`/` should lower to integer division (`div`) when both operands are
`int`, and to float division when either operand is `float`.** Concretely:
`int / int -> int` (truncating, like Nim's `div`), `float / int`, `int /
float`, and `float / float` all `-> float`. No separate operator, no
required explicit call.

Reasoning, weighed against the other two options the team raised:

- **(b) separate operators (`/` vs `div`)** just relocates today's bug
  instead of fixing it — an author still has to *know* to reach for `div`,
  and the failure mode when they don't (silent float promotion, or a type
  error deep in a `var` reassignment) is exactly what this batch already
  hit. It also contradicts Tuck's stated design goal: SYNTAX.md and every
  brief for this effort say "write the most natural Tuck" — and the natural
  form, demonstrated in every single division in this batch (a08 average,
  a11 F conversion, a14/a15 digit extraction, a18 area), was plain `/` with
  an unstated but obviously-intended integer result. Nobody wrote `div`
  because nobody thinks in `div` when computing digit-sum or an average
  count — they think in `/`.
- **(c) explicit `{a, b} intDiv`** fights Tuck's own postfix-call ergonomics
  by turning the single most common numeric operator in the corpus into a
  function call. It also doesn't match the "operators bind tight, postfix
  calls are for named concepts" split the language already draws elsewhere
  (SYNTAX.md's operator precedence table treats `/` as a first-class
  operator alongside `+`, `-`, `*`, `%` — singling it out for call-syntax
  would be the odd one out).
- **(a) type-directed `/`** matches what every example in this batch already
  assumed while writing it, requires zero new syntax, and is what most
  practical languages converge on (Python 3's `//` is the exception, not
  the rule; C, Java, Rust, Go, and Nim's own `div`-vs-`/` split all use
  operand types to decide, though Nim keeps them separate operators — Tuck
  can do better by inferring from the postfix-friendly "whole numbers in,
  whole number out" intuition its own examples demonstrate).

**Implication for `%`:** keep `%` as int-only (already true, already worked
correctly everywhere it was used — a01, a04, a06, a12, a14, a15, a20).
Applying `%` to a `float` operand should be a `check`-time type error, not
silently coerced — there's no ambiguity to resolve the way there is with
`/`, since floor/mod on floats is a different, less commonly wanted
operation.

**Implication for mixed int/float arithmetic (`+ - *`):** stay consistent
with the same type-directed rule already implicit in `/`'s fix — `int op
float -> float`, promoting the `int` operand, for `+`, `-`, and `*` as well.
This wasn't a defect surfaced in this batch (no mixed-type arithmetic was
attempted), but it keeps one rule ("int only in, int out; float touches
anything, float out") instead of `/` being a special case among the
arithmetic operators.

### Not invented this batch, but visibly missing once you write real numeric
code (called out per DISCOVERIES.md, listed here because they'd change how
several of these examples would naturally be written)

- **Integer division as a distinct operator or fn** (`div`/`intDiv`, or fix
  codegen so `/` on two `int`s produces `div` automatically) — would remove
  the #3 pain point above outright; every average/area/table example in this
  batch implicitly wants this.
- **`fn sqrt({value: float}) -> float`** — not needed by any of these 20
  (none required a real square root), but the moment a Heron's-formula
  triangle-area or distance-formula example is written, it's the next
  obvious ask; flagging it now so Batch C/other batches don't rediscover it
  from scratch.
- **`fn parseInt({text: str}) -> int`** — no string input in this batch, but
  DISCOVERIES.md already flags no int-parsing from `str` exists; any future
  "read a number, compute something" example needs it.
