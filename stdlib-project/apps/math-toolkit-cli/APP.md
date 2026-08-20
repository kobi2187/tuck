# App: math-toolkit-cli

A single CLI with several subcommands that share one theme — real numerical work, not just arithmetic: `mtk convert 12.5 mi km`, `mtk fx 100 USD EUR --rate-file rates.json`, `mtk stats data.csv --column price` (mean/median/stddev/percentiles), `mtk orbit --altitude-km 400` (a simple circular-orbit period calculator), `mtk money "19.99" + "5.005"` (exact decimal arithmetic, no float rounding surprises).

## Why this is a good validation target
None of the first eleven apps seriously exercises `std.math` beyond incidental arithmetic. This app is a purpose-built stress test for its three genuinely distinct numeric domains — floating-point elementary functions, arbitrary-precision decimal (money must never use binary float), and descriptive statistics — which most languages' "one math module" design conflates or under-serves.

## Features
- Unit conversion across a small table of physical units (length, mass, temperature) — deliberately not exhaustive, just enough to prove the pattern.
- Currency conversion from a local rate table (JSON), using exact decimal arithmetic throughout (no float drift in money math).
- Descriptive statistics over a CSV column: mean, median, variance/stddev, and arbitrary percentiles (p50/p90/p99).
- A physics one-liner (orbital period from altitude) exercising elementary functions (sqrt, pow, pi) and unit consistency.
- Exact decimal arithmetic subcommand demonstrating correct rounding modes (banker's rounding vs. round-half-up, user-selectable).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.math` | the module under direct test — `Decimal` for money, elementary functions for orbital calc, statistics functions for the CSV analysis |
| std | `std.encoding` | reading the CSV data column and the JSON rate table |
| std | `std.cli` | subcommand parsing, tabular output |
| std | `std.testing` | exact-arithmetic correctness is the kind of thing that needs property tests (`convert(convert(x, A, B), B, A) == x` within epsilon; `Decimal` addition never silently loses a cent) |
| sys | `sys.fs` | reading the CSV/JSON input files |
| core | `core.num` | checked arithmetic underneath `Decimal`, avoiding silent overflow in the statistics accumulation |
| core | `core.error` | malformed numeric input, division by zero, unit-conversion table misses |

## Anticipated API stress points
`std.math`'s `Decimal` type needs a selectable rounding mode as a first-class parameter (not a global setting), because money math (round-half-even, the accounting standard) and casual unit conversion (round-half-up, what a human expects) genuinely want different defaults, and forcing one global choice would make one of the two subcommands wrong. The statistics functions need to operate over a streaming iterator (so `mtk stats` doesn't have to load a huge CSV fully into memory) rather than requiring a materialized slice — a direct test of whether `std.math` composes with `core.iter` the way Design Principle 3 expects, or whether it was designed as an isolated batch-only module.
