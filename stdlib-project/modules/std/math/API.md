# std.math

## Purpose
Elementary functions, descriptive statistics, arbitrary-precision integers and rationals, and a base-10 decimal type for exact monetary arithmetic — the numeric surface `core.num` deliberately leaves out because it requires allocation.

## Design lineage
Modeled on Python's `decimal` (exact, base-10, configurable-precision arithmetic that never silently introduces binary-floating-point rounding error into money math) and `fractions` (exact rational arithmetic) for the `Decimal`/`Rational` types, and Go's `math/big` for the arbitrary-precision integer API shape (`BigInt` with explicit, checked operations rather than operator overloading that could silently overflow expectations).

## Proposed API
```
// Elementary functions — thin, allocation-free wrappers; live here (not core.num) only because
// this module is where they're discoverable alongside the rest of std's numeric surface.
mod elementary {
    fn sqrt(x: f64) -> f64; fn pow(base: f64, exp: f64) -> f64;
    fn ln(x: f64) -> f64; fn log2(x: f64) -> f64; fn log10(x: f64) -> f64;
    fn sin(x: f64) -> f64; fn cos(x: f64) -> f64; fn tan(x: f64) -> f64; fn atan2(y: f64, x: f64) -> f64;
}

// Statistics over any iterator of f64 — composes with core.iter, no Vec required up front.
mod stats {
    fn mean(xs: impl core::iter::Iterator<Item = f64>) -> f64;
    fn variance(xs: impl core::iter::Iterator<Item = f64>) -> f64;      // population variance
    fn stddev(xs: impl core::iter::Iterator<Item = f64>) -> f64;

    // Added for math-toolkit-cli: mean/variance/stddev each fully consume a *by-value* iterator
    // (core.iter's Iterator::next takes &mut self but the adapter chain itself is owned/moved),
    // so a caller wanting more than one of the three from a single-pass source (a CSV column
    // reader that can't cheaply be replayed) cannot call mean() then variance() on the same
    // iterator — the second call gets an already-exhausted source. `describe` computes all three
    // in one pass via Welford's online algorithm (the same single-pass-fold shape core.iter's own
    // validation note for this app confirms mean/variance already reduce to) so the common
    // "give me mean, stddev, and n" request never requires collecting into a Vec or re-reading
    // the column twice.
    struct Summary { count: u64, mean: f64, variance: f64, stddev: f64 }
    fn describe(xs: impl core::iter::Iterator<Item = f64>) -> Summary;

    // median/percentile inherently need order statistics, which core.iter's own validation note
    // confirms cannot be done lazily — the caller collects the column into an alloc.vec::Vec<f64>
    // first (the same core/alloc split todo-cli's sort requirement already established). Given
    // that materialization already happened, these take `&mut [f64]` rather than `&[f64]` so the
    // required sort happens in place, on the caller's already-owned buffer, instead of `std.math`
    // silently cloning it internally — for `mtk stats` on a genuinely large CSV column, a hidden
    // clone-to-sort would double the resident memory for no reason.
    fn median(xs: &mut [f64]) -> f64;
    fn percentile(xs: &mut [f64], p: f64) -> f64;
    // p50/p90/p99 in one command means naively calling `percentile` three times sorts the same
    // buffer three times (O(n log n) each) for no reason — `percentiles` sorts once and answers
    // every requested quantile from that one ordering.
    fn percentiles(xs: &mut [f64], ps: &[f64]) -> alloc::vec::Vec<f64>;
    fn correlation(xs: &[f64], ys: &[f64]) -> f64;                      // Pearson r

    // Added for load-tester — see "Key design decisions" below for why this is a genuinely
    // different API shape from percentiles(), not just a wrapper around it. An online estimator
    // for p50/p90/p99-style quantiles over a data stream too large (or too continuous) to
    // re-sort on every observation, bounded memory regardless of how many values are recorded.
    struct TDigest {
        compression: f64,   // accuracy/memory knob; higher = more accurate, more centroids retained
    }
    impl TDigest {
        fn new(compression: f64) -> TDigest;   // recommended_compression() below for a sane default
        fn recommended_compression() -> f64;
        fn record(&mut self, x: f64);           // O(log centroids) amortized, no allocation on the common path
        fn quantile(&self, q: f64) -> f64;      // 0.0..=1.0; approximate, error bounded by compression
        fn merge(&mut self, other: &TDigest);   // combine digests from independent recorders (e.g. per-worker)
    }
}

// Arbitrary-precision integer
struct BigInt;
impl BigInt {
    fn from_i64(v: i64) -> BigInt;
    fn parse(s: &str, radix: u32) -> core::types::Result<BigInt, core::error::Error>;
    fn add(&self, other: &BigInt) -> BigInt;
    fn mul(&self, other: &BigInt) -> BigInt;
    fn div_rem(&self, other: &BigInt) -> core::types::Result<(BigInt, BigInt), core::error::Error>;  // Err on divide-by-zero
    fn pow(&self, exp: u32) -> BigInt;
    fn to_string_radix(&self, radix: u32) -> alloc::string::String;
}
impl core::cmp::Ord for BigInt { /* total order, via core.cmp */ }

// Exact rational
struct Rational;
impl Rational {
    fn new(numerator: BigInt, denominator: BigInt) -> core::types::Result<Rational, core::error::Error>; // reduces to lowest terms; Err if denom == 0
    fn add(&self, other: &Rational) -> Rational;
    fn mul(&self, other: &Rational) -> Rational;
    fn to_f64(&self) -> f64;    // explicit, lossy — never implicit
}

// Decimal — exact base-10, for money. Never mixes implicitly with f64.
struct Decimal;                                     // fixed-point, arbitrary digits, tracks scale explicitly
impl Decimal {
    fn from_str(s: &str) -> core::types::Result<Decimal, core::error::Error>;   // "19.99" parsed exactly, no binary rounding
    fn from_i64_scaled(units: i64, scale: u32) -> Decimal;                       // e.g. cents: from_i64_scaled(1999, 2)
    fn add(&self, other: &Decimal) -> Decimal;
    fn mul(&self, other: &Decimal) -> Decimal;
    // Added for math-toolkit-cli: `add`/`mul` never round (scale only grows: sum keeps
    // max(scale1, scale2), product keeps scale1+scale2 — both exact), so no mode parameter
    // belongs on them. Division is different: it can be non-terminating (1/3) even for exact
    // Decimal operands, so unlike add/mul it cannot return an exact Decimal without a caller-
    // chosen stopping point — `div` takes the target scale and rounding mode explicitly, the
    // same per-operation shape `round` already has, and returns Err on division by zero rather
    // than panicking on user-controlled input (rate-table/CSV values), consistent with this
    // module's existing fallibility stance for BigInt/Rational.
    fn div(&self, other: &Decimal, scale: u32, mode: RoundingMode) -> core::types::Result<Decimal, core::error::Error>;
    fn round(&self, scale: u32, mode: RoundingMode) -> Decimal;
    fn to_string(&self) -> alloc::string::String;    // exact textual form, never scientific notation by default
}
enum RoundingMode { HalfUp, HalfEven, Down, Up }      // HalfEven ("banker's rounding") available, not default
```

## Key design decisions
- **`Decimal` has no implicit conversion to/from `f64`** — every path between them is an explicit, named, and (in the `f64 -> Decimal` direction) fallible call, because the entire reason `Decimal` exists is that `0.1 + 0.2 != 0.3` in binary floating point, and an implicit conversion would silently reintroduce the exact bug the type exists to prevent.
- **`stats` functions take iterators, not `Vec<f64>`, wherever a single pass suffices** (`mean`, `variance`, `stddev`) — only functions that inherently need random access or sorting (`median`, `percentile`) require a slice — matching Principle 3's "compose with `core.iter`" preference and avoiding forcing a full materialized collection for a streaming statistic.
- **`BigInt`/`Rational`/`Decimal` operations return new values (immutable, no in-place mutation methods) and division/construction that can fail returns `Result`**, never panics on divide-by-zero or a malformed denominator — arbitrary-precision arithmetic is exactly the place silent panics on user-controlled input (e.g. a parsed price string) would be most damaging.
- **`Decimal` tracks scale (number of digits after the point) explicitly rather than normalizing it away** — `Decimal::from_str("19.90")` and `Decimal::from_str("19.9")` are numerically equal but round-trip back to their original textual scale, which matters for money display (`"19.90"` vs `"19.9"` are not interchangeable to a user) in a way a normalized/canonical representation would lose.
- **Revision (math-toolkit-cli):** the original design already had `RoundingMode` as a `round(scale, mode)` parameter rather than a module-level or type-level default, so the app's headline stress point — money wants `HalfEven`, casual unit conversion wants `HalfUp`, and one CLI process runs both subcommands in the same execution — is satisfied by the existing shape with no change: `mtk money` calls `.round(2, RoundingMode::HalfEven)`, `mtk convert` calls `.round(n, RoundingMode::HalfUp)`, and there is no global rounding-mode state either subcommand could leave set for the other. What the app *did* force a change to is `Decimal::div`, which did not exist at all — general unit conversion (`mi` → `km` → some third unit through a common base factor) and any future percentage/rate math need division, and unlike `add`/`mul` a Decimal division is not always exact, so it needed the same explicit `(scale, mode)` shape `round` already uses, not a silent default precision.
- **Revision (math-toolkit-cli):** `stats::median`/`percentile` changed from `&[f64]` to `&mut [f64]`, and a new `stats::percentiles` (plural) was added, because `mtk stats data.csv --column price` requests p50/p90/p99 together — three calls to a slice-taking `percentile` would either sort a large CSV column three times or require `std.math` to clone-then-sort internally on every call, and the "large CSV column" framing this app is explicitly built around makes both costs real rather than theoretical. A new `stats::describe` (mean/variance/stddev/count in one Welford's-algorithm pass over a `core.iter` iterator) was added alongside the pre-existing single-purpose `mean`/`variance`/`stddev` functions for the same reason: those functions each *consume* their argument iterator, so getting more than one statistic from a genuinely single-pass source (not a replayable `Vec`) previously had no supported path.
- **Revision (load-tester), RESOLVED with a genuinely new type rather than a "just call it less often" answer:** `math-toolkit-cli`'s `stats::percentiles(&mut [f64], &[f64])` is a one-shot batch operation — sort the whole buffer once, answer every requested quantile from that ordering — which is the right shape for "run once at the end over a CSV column already fully in memory." `load-tester` is a different problem: p50/p90/p99 need to be visible as *live, continuously-updating* numbers throughout a run that may be recording thousands of latency observations per second for up to `-d 30s` (tens of thousands of samples), and the live progress display (`std.cli`) redraws on an interval, not once at the end. The question this app forces is whether "compute `percentiles` periodically instead of per-request" is by itself a sufficient answer, and it is not, for two concrete reasons: (1) `percentiles` requires the *entire* history as a contiguous, sortable `&mut [f64]` — even "periodic, not per-request" means re-sorting an ever-growing buffer (10k, then 20k, then 30k samples) every time the display refreshes, which is wasted repeated O(n log n) work over a prefix that's already been sorted before, and the buffer itself grows unbounded for the run's duration; (2) more fundamentally, `percentiles` needs the raw samples retained in memory at all to be recomputed from, which is exactly the kind of overhead the app's own requirement ("recording itself shouldn't skew results") is warning against at high request rates — retaining and repeatedly re-touching tens of thousands of `f64`s on the same process that's also driving hundreds of concurrent request tasks is measurement overhead bleeding into the measurement. The resolution is a genuinely different API, not a scheduling change to the existing one: `stats::TDigest`, a streaming/online quantile estimator (t-digest, the same family used by Prometheus/DataDog/ES for exactly this "live approximate percentiles over a stream" problem) — `record(x)` is O(log centroids) amortized with no per-call allocation on the common path, memory stays bounded by the `compression` parameter regardless of how many samples are ever recorded (contrast: `percentiles`' `&mut [f64]` is O(n) memory, unbounded in the number of samples), and `quantile(q)` reads back an approximate answer at any time without needing the raw sample history at all. `TDigest::merge` exists because `load-tester`'s `-c 200` concurrent request tasks each observe their own latencies independently — a per-worker-task local `TDigest` (no lock, no cross-task contention on the hot per-request path) merged periodically into one display-facing digest is the natural shape given `std.async`'s executor-model resolution this round: a shared digest touched on every request would be exactly the contended-hot-lock case that resolution warns against, while per-task digests merged on the same low-frequency interval `std.cli`'s progress redraw already uses cost nothing extra. `stats::percentiles` is unchanged and remains the right tool for `math-toolkit-cli`'s one-shot, fully-materialized-column case; `TDigest` is additive, not a replacement — the two solve different problems (exact batch vs. approximate streaming) and this module now offers both rather than stretching one shape to cover both.

## Validated by applications
- **secrets-vault**: does not use `std.math` — a small negative check that the module's presence costs nothing for apps with no numeric surface beyond simple counters, which is otherwise handled by `core.num`.
- **todo-cli**: uses `stats` indirectly through `--practice`-style aggregate reporting is actually `cli-hangman`'s territory (see below); `todo-cli` itself has no `std.math` dependency either, reinforcing that most CLI apps in this survey don't need more than `core.num`'s checked arithmetic — `std.math` earns its `std`-tier placement specifically for the apps that do.
- **cli-hangman**: `--practice` mode's win-rate stat (`games_won / games_played`) is simple enough it doesn't strictly need `std.math`, but was used as the concrete test for whether `stats::mean` over a small in-memory iterator of 0.0/1.0 outcomes is more legible than hand-written accumulation — confirmed it is, and this shaped keeping `stats` functions iterator-first rather than requiring a pre-built `Vec` for a two-line use case.
- **doc-convert-tester**: exercises `Decimal` and `Rational` indirectly through CSV/JSON/TOML round-tripping of numeric table cells — a CSV cell like `"19.90"` must decode to a `Decimal` (not `f64`) and re-encode to the identical string for the round-trip diff to pass, which is the concrete forcing function behind the scale-preservation design decision above; this app is also where `Rational::to_f64`'s explicit-lossy naming mattered, since an implicit conversion during format conversion would have silently broken exact round-tripping for fractional TOML/JSON values.
- **math-toolkit-cli**: the first app to seriously exercise this module rather than touch it incidentally, and it stresses all three numeric domains at once in one process — `elementary::sqrt`/`pow` for `mtk orbit`'s circular-orbit period, `Decimal` for `mtk money` (exact add, `HalfEven` rounding) and `mtk fx`/`mtk convert` (`mul` then `round`/`div` with `HalfUp`, see the revisions above), and `stats::describe`/`stats::percentiles` for `mtk stats data.csv --column price`. It's also the app that confirms the `stats` module's iterator-first design (Key design decisions, above) actually holds under a real streaming source rather than the small in-memory case `cli-hangman` exercised: `describe` runs as a single `fold` over the CSV-column iterator with no intermediate `Vec`, while `median`/`percentiles` require the caller to `collect()` first — the same lazy/eager split `core.iter`'s own validation note for this app documents, now confirmed concrete on the `std.math` side of that boundary too. Malformed numeric cells (a CSV price column with a stray non-numeric row) surface as `core::types::Result` at the CSV-decode boundary in `std.encoding`, before a value ever reaches `stats` — `std.math`'s functions themselves stay total over `f64`/`Decimal`, never partial over raw text.

- **load-tester**: the forcing case for `stats::TDigest` above — each of the run's concurrent request tasks records its own latency into a task-local `TDigest` on every response (no shared state, no lock on the hot path), and a low-frequency periodic task (same cadence as the `std.cli` live-progress redraw, not per-request) merges the per-task digests into one display-facing `TDigest` and reads back p50/p90/p99 for the running display; the final report re-merges once more for the summary. This is also the app that establishes `TDigest`'s memory-boundedness matters concretely, not just asymptotically: a 30-second run at a few thousand requests/second is tens of thousands of samples, and the app's own stated requirement — "recording itself shouldn't skew results" — is precisely the requirement `stats::percentiles`' O(n)-retained-samples shape cannot satisfy at this call frequency, which is why this app gets a genuinely new type rather than a citation of the existing batch function.

## Open questions / risks
Whether `Decimal`'s maximum precision/scale should be a compile-time-fixed bound (for predictable, allocation-free arithmetic in hot paths) or fully arbitrary like `BigInt` (simpler mental model, at the cost of allocation on every operation) is unresolved; the API above assumes arbitrary precision by default, deferring a fixed-width `Decimal64`-style variant to a possible future addition if a performance-sensitive app surfaces the need.
