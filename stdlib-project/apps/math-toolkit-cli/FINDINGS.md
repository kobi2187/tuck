# math-toolkit-cli — dogfooding findings

## What was built

`mtk.tuck` covers two of APP.md's five subcommands, with hardcoded inputs
instead of CLI/file parsing: unit conversion (miles<->km round trip, plus
Celsius->Fahrenheit) and descriptive statistics (mean, variance, stddev,
median) over a fixed 7-element `Seq[f64]`. It typechecks (`./tuck ch`),
builds on the Nim backend (`./tuck b`), and runs, printing both a conversion
summary and a stats summary. Out of scope, per the task brief: CSV/JSON
parsing, currency conversion, `Decimal` exact-money arithmetic, configurable
rounding modes, percentiles other than the median, and streaming/`core.iter`
composition. Tuck has no arbitrary-precision decimal type today — money math
would need one built from scratch, clearly outside a small dogfood slice.

## Missing stdlib functions needed

- **`std.math` (proposed new module): `fn sqrt({x: f64}) -> f64`** — no
  elementary math functions (`sqrt`, `pow`, trig, `pi`) exist anywhere in the
  compiler or `std/` today (checked `std/*.tuck` and `compiler/tuck_rt.nim`).
  Stubbed via `pending:` in `mtk.tuck:25-26` so `stddev` still typechecks and
  runs (it prints `0.0` at runtime, logged as `TUCK PENDING: tuck_sqrt
  invoked`) — this is the intended walking-skeleton behavior, not a bug.
  `pow` would be needed for `mtk orbit`'s circular-orbit formula; not stubbed
  here since that subcommand wasn't in scope.
- **`Seq.len`** — already flagged in `std/str.tuck`'s header comment and
  TODO.md §3 as declared nowhere. I avoided it entirely by iterating with
  `for x in data:` (which does work without `.len`, spec line 317) and by
  hardcoding the sample size as a `count: f64` parameter and the median's
  index as a literal `3`. A real `stats` subcommand over arbitrary-length
  data needs `Seq.len` (and a sort) to generalize percentiles; without it,
  `median`/`percentile` can only work over a known, pre-sorted, fixed-size
  input, which is why the slice stops at "median of a 7-element literal."
- **A sort function** (e.g. `std.seq`'s `fn sorted[T]({items: Seq[T]}) ->
  Seq[T]`) — needed for any real percentile function; not stubbed, just
  worked around by hand-sorting the literal array and noting it in a
  comment (`mtk.tuck:44-47`).

## Compiler bugs / friction hit

**Real, reproduced bug: `distinct` over a float base type cannot build on
the Nim backend.** `compiler/codegen_decl.nim:275` unconditionally emits
borrowed `div` and `mod` operators for every `distinct` type:

```nim
for op in ["+", "-", "*", "div", "mod"]:
  res.add("proc `" & op & "`*(a, b: " & d.name & "): " & d.name & " {.borrow.}\n")
```

Nim's `div`/`mod` exist only for integer types, not `float32`/`float64`. Any
`distinct X = f32` or `distinct X = f64` therefore fails Nim compilation.
Minimal repro (`/tmp/tuck-math-scratch/distinct_test2.tuck`, not committed):

```tuck
distinct Miles = f64
fn miles(value: f64) -> Miles:
  value Miles
fn main() -> void [io]:
  let d = 12.5 miles
```

`./tuck ch` reports `OK` (typechecks fine), but `./tuck b` fails at the Nim
stage with:

```
distinct_test2.nim(9, 6) Error: type mismatch
Expression: div(a, b)
  [1] a: float64
  [2] b: float64
Expected one of (first mismatch at [position]):
[1] proc `div`(a, b: tuck_Miles): tuck_Miles
...
```

The Odin and D backends (`./tuck c --odin`, `./tuck c --dlang`) both emit
without error for the same source — this is Nim-backend-specific. This
matters directly for math-toolkit-cli: LANGUAGE-OVERVIEW's own recommended
pattern for unit-safe values (`distinct Miles = f64`, `distinct Kilometers =
f64`, mirroring `std/time.tuck`'s `distinct Milliseconds = u32`) is exactly
the natural way to write a unit-conversion tool, and it is currently
unbuildable for any real-valued (non-integer) unit. `mtk.tuck` was written
with plain `f64` parameters instead, noted in its header comment. The fix is
a one-line guard in `genAliasType` (skip `div`/`mod` when the base type is
`f32`/`f64`) — did not touch it per the task's "don't edit `compiler/`"
boundary, logging it here instead.

No other compiler bugs hit. `Seq` literals (`[9.0, 12.0, ...]`), `for x in
seq:` iteration, `/f` float division, string concatenation with `+`, and
generic `toStr` all worked exactly as documented on the first try.

## Interface/mixin/actor design notes

None of `interface`, `mixin`, or `actor` earn their place in this slice.
There's no polymorphism point (conversions and stats are each a fixed set of
pure functions over `f64`/`Seq[f64]`) and no shared mutable coordinator to
justify an `actor`. If APP.md's full scope were built, `RoundingMode` (as
described in APP.md's "Anticipated API stress points" — banker's vs.
round-half-up, selected per call) is a genuine `interface` candidate: two
concrete rounding strategies satisfying one contract, dispatched at the call
site, not through a global setting. Not built here since `Decimal`/money is
out of scope. Nothing here felt like it wants to be a cross-app shared
mixin — unit conversion and stats are domain-specific enough that a mixin
would just be a header for a struct nobody else needs.

## Joy-of-use verdict

Pleasant for the part that's implemented: the payload-call style
(`{miles: miles} milesToKm`) reads well for pure math functions, `/f` makes
float-vs-int division an explicit, non-surprising choice, and `pending:`
made it easy to keep `stddev` wired into the real call graph without writing
`sqrt` myself or blocking the rest of the file. The rough edge is entirely
in `std.math`'s near-total absence — this app's whole reason for existing
(per APP.md) is stressing floating-point elementary functions, arbitrary
precision decimals, and streaming statistics, and today's stdlib has none of
the three, so the "real slice" that's actually buildable is much smaller
than the app's premise. The `distinct`-over-float bug was the one place
Tuck's own documented best practice (unit types) didn't work in practice.
