# std.math — Nim API

## Purpose
The three numeric worlds a program actually meets, kept apart on purpose: floating point for measurement, `Decimal` for money, and statistics for describing a pile of numbers you cannot hold in memory all at once.

## Protocols implemented
`Collection` on `Summary` and `Quantiles` (both enumerate what they hold). `Adjustable` on `Decimal`. Everything else is domain verbs — arithmetic has its own vocabulary older than any standard library, and `add(price, tax)` would be worse than `price + tax`, not better.

## The API

```nim
type
  Decimal* = object
    ## Exact base-10 arithmetic. No binary float ever touches a price.
  Rounding* = enum
    HalfEven      ## accounting's default — what banks do
    HalfUp        ## what a person expects when splitting a bill
    Down, Up, TowardZero

proc toDecimal*(text: TextView): Decimal        ## raises on garbage
proc tryToDecimal*(text: TextView): Option[Decimal]
proc `+`*(a, b: Decimal): Decimal               ## exact; never rounds
proc `-`*(a, b: Decimal): Decimal
proc `*`*(a, b: Decimal): Decimal               ## exact; scale is the sum of scales
proc divide*(a, b: Decimal; places: int; rounding = HalfEven): Decimal
  ## The one operation that can run forever, so it must be told where to stop.
  ## Both arguments are required — there is no "sensible default" for money.
proc round*(d: Decimal; places: int; rounding = HalfEven): Decimal
proc adjust*(d: var Decimal; delta: Decimal)    ## relative change, per the verb table
proc show*(d: Decimal): Text                    ## core.fmt's Showable

type Summary* = object
  count*: int
  mean*, variance*, deviation*, smallest*, largest*: float

proc describe*(numbers: iterable[float]): Summary
  ## One pass, Welford's algorithm, no allocation, no second look at the data.
  ## Works on a file you are streaming and could not fit in memory.

type Quantiles* = object
  ## Online percentile estimate (t-digest). Bounded memory whatever the input size.
proc newQuantiles*(accuracy = 100): Quantiles
proc add*(q: var Quantiles; value: float): bool {.discardable.}
proc get*(q: Quantiles; fraction: float): Option[float]   ## get(q, 0.99) → p99
proc merge*(into: var Quantiles; other: Quantiles)
  ## Per-worker digests combine at the end, so no shared lock on the hot path.

proc median*(numbers: var openArray[float]): Option[float]
  ## Sorts in place. `var` in the signature is the warning: this rearranges your data.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Decimal::div(other, scale, mode)` | `divide(a, b, places, rounding)` | "scale" is jargon for "how many digits after the point"; `places` is the word on a calculator |
| `RoundingMode::HalfEven` | `HalfEven` with a `## what banks do` comment | the name stays (it is standard) but the doc comment answers "which one do I want" in four words |
| `stats::describe()` | `describe(numbers)` | unchanged, and it earns its place: one call replaces `mean` + `variance` + `stddev` + `count`, each of which would consume the iterator separately |
| `TDigest` | `Quantiles` | names what you get, not the paper it came from |
| `t.quantile(0.99)` | `get(q, 0.99)` | the structural verb; a percentile *is* a lookup by key, and the key happens to be a fraction |
| `percentiles(&mut [f64], &[f64])` | `Quantiles` + `median` | the batch version survives only as `median`, because `load-tester` proved the batch shape distorts what it measures |
| `checked_div` | `divide` raising | the `try` rule covers it; a second name is not needed |

## In use

```nim
# math-toolkit-cli: money, where a float would silently lose a cent
let subtotal = "19.99".toDecimal + "5.005".toDecimal
echo subtotal.round(places = 2, rounding = HalfEven).show()   # 25.00, not 24.995

# load-tester: p99 while the test is still running, without disturbing it
var latency = newQuantiles()
for reply in responses: latency.add(reply.elapsed.millis.float)
echo "p99 ", latency.get(0.99).get()

# math-toolkit-cli again: statistics over a CSV column too big to hold
echo describe(csvColumn(file, "price")).mean
```

## Vocabulary exceptions
Arithmetic keeps its operators (`+`, `-`, `*`) rather than being forced into `add`/`adjust`. The verb table describes operations on containers and resources; a number is neither, and `a.add(b)` for `a + b` would be the vocabulary making code worse to satisfy itself. `describe`, `median`, `merge` and `divide` are domain verbs. `adjust` on `Decimal` is the one structural verb that fits honestly — a running total genuinely is relative change — and it is kept for exactly that case.
