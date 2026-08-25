# sys.time — Tuck translation

## This module already exists — `std/time.tuck` is real, implemented code.

Unique among the 72: this isn't a translation, it's a **diff against
working code**. `std/time.tuck` already ships `nowMs`, `sleepMs`, the
`Milliseconds`/`Microseconds`/`Seconds` distinct types, and the
`ms`/`us`/`s` helper fns that make `5.ms` work.

**Compiler-verified**, `./tuck ch`: `OK`.

## What the real module already has, and got right

```tuck
distinct Milliseconds = u32
distinct Microseconds = u32
distinct Seconds = u32

fn ms(value: u32) -> Milliseconds:
  value Milliseconds

extern:
  fn nowMs() -> {ms: u64} [io]
  fn sleepMs({ms: u32}) -> void [io]
```

Two design notes in that file are worth keeping visible, because they
answer questions the Nim design also faced:

- **Duration units are distinct over their bit width** — "same bits at
  runtime, incompatible at compile time." That is the Nim design's
  `Duration` type-safety goal, achieved without a `Duration` type.
- **`5.ms` is postfix application, not unit magic** — "no unit magic in the
  compiler." `ms`/`us`/`s` are ordinary fns.

## What the Nim design adds that isn't there yet

```tuck
pending:
  fn nowMonotonicMs() -> {ms: u64} [io]
  fn elapsedMs({sinceMs: u64}) -> {ms: u64} [io]
  fn unixSeconds() -> {s: i64} [io]
```

- **`Instant` vs `Timestamp` is the important missing distinction.** The
  Nim design (following Java's `java.time`, which the report calls the
  best-designed date/time API surveyed) keeps *monotonic* and *wall-clock*
  as genuinely different, non-interchangeable types — because subtracting
  wall-clock readings across an NTP step or a DST change gives nonsense,
  and the type system should refuse it. `std/time.tuck` currently has only
  `nowMs`, and its comment doesn't say which it is.

  **The distinct-type mechanism to fix this already exists in the file** —
  the same one `Milliseconds` uses. `distinct Instant = u64` and
  `distinct Timestamp = u64` would make the mixing a compile error, at no
  runtime cost.
- **`elapsed`/`since` saturating at zero** rather than wrapping — the Nim
  design's `since(later, earlier)` "saturates at zero rather than
  wrapping." With `[saturating]` available as a type attribute, that could
  be declared rather than implemented.

## The performance question the Nim design flagged, still open
Round-3 recorded that `Instant::now()`'s cost on a hot path (`load-tester`
calls it thousands of times a second) depends on the OS mechanism (vDSO,
`QueryPerformanceCounter`) and "this project's analysis-only scope can name
but not verify." `std/time.tuck` being real code means it *can* now be
measured — `benches/` exists, and this is a good candidate.
