# sys.time

## Purpose
Provides two strictly separate time types — `Instant` (monotonic, for measuring elapsed durations) and `SystemTime` (wall clock, for timestamps) — plus a `Duration` value type used uniformly by every module that expresses a time span.

## Design lineage
Modeled directly on Rust's `std::time::{Instant, SystemTime, Duration}` split, which the report calls out by name as avoiding "a recurring real-world bug source" (NTP adjustments, DST changes, and manual clock changes silently corrupting elapsed-time math when a single `Time` type is used for both purposes, as in older APIs like C's `time()`/`clock()` ambiguity or JavaScript's single `Date`). Go's `time.Now()`/`time.Since()` is the secondary reference for API ergonomics (a `Duration` returned directly from a subtraction-shaped call), though Go's own `Time` type controversially conflates monotonic and wall-clock readings internally — a conflation this design deliberately does not repeat.

## Proposed API
```
struct Instant { .. }              // opaque, monotonic; not comparable across processes/reboots
impl Instant {
    fn now() -> Instant;
    fn elapsed(&self) -> Duration;                    // now() - self, saturating at zero
    fn duration_since(&self, earlier: Instant) -> Duration;   // saturating, never panics/negatives
    fn checked_duration_since(&self, earlier: Instant) -> Option<Duration>;
    fn checked_add(&self, d: Duration) -> Option<Instant>;
}

struct SystemTime { .. }           // wall clock; can jump backward/forward (NTP, user change)
impl SystemTime {
    fn now() -> SystemTime;
    fn duration_since(&self, earlier: SystemTime) -> Result<Duration, SystemTimeError>;  // fails if earlier > self (clock went backward)
    const UNIX_EPOCH: SystemTime;
}

struct Duration { .. }             // core-tier value type (no OS dependency), re-exported here
impl Duration {
    fn from_secs(s: u64) -> Duration;
    fn from_millis(ms: u64) -> Duration;
    fn from_micros(us: u64) -> Duration;
    fn from_nanos(ns: u64) -> Duration;
    fn as_secs_f64(&self) -> f64;
    fn checked_add(&self, other: Duration) -> Option<Duration>;
}

fn sleep(d: Duration);             // re-exported / aliased from sys.thread::sleep for discoverability
```

## Key design decisions
- `Instant` has no method to convert to a wall-clock timestamp, no `Display`/formatting, and is explicitly documented as non-comparable across process restarts or machine reboots — this is enforced by giving it an opaque internal representation rather than a `u64` nanosecond count an app could be tempted to serialize and compare later, closing off the exact misuse that causes the "recurring real-world bug."
- `SystemTime::duration_since` returns `Result`, not a plain `Duration`, because the wall clock can move backward (NTP correction, manual adjustment) — a subtraction that would naively underflow instead surfaces `SystemTimeError` explicitly, forcing every caller doing wall-clock arithmetic to consider the backward-jump case rather than silently wrapping to a huge duration.
- `Duration` itself lives conceptually at `core` (it's a pure value type, no syscalls) but is re-exported from `sys.time` as the canonical spelling every `sys`/`std` API references, so `sys.thread::sleep`, `sys.sync::Condvar::wait_timeout`, and `sys.net` timeouts all share literally the same type — one idiom for "how long," per Principle 4.
- No timezone-aware calendar arithmetic here at all (no year/month/day, no timezone database) — that's explicitly `std.chrono`'s job; `sys.time` only ever hands back an opaque instant, a raw wall-clock point, or a duration, keeping the `sys` tier thin per Principle 5.

## Validated by applications
- **mp3-player**: the playback-position display (updated ~4x/sec) is explicitly required to use a monotonic `Instant`-based clock "independent of wall-clock changes" — if the user's system clock adjusts mid-playback (NTP sync, manual change, DST), a `SystemTime`-based position counter would visibly jump or reverse. This app is the direct, named validation that the `Instant`/`SystemTime` split isn't academic: a naive single-`Time`-type design would produce a real, user-visible playback-position glitch.
- **secrets-vault**: the clipboard auto-clear timer is a duration-until-fire computation from an `Instant`, not a `SystemTime` deadline — this confirmed `checked_add`/`elapsed` on `Instant` needed to be ergonomic enough for a simple "clear in N seconds" timer without the app reaching for `SystemTime` out of habit (which would be subtly wrong if the clock changes during the wait).
- **load-tester** (Extension round 3): the sharpest test yet of `Instant::now()` specifically as a *hot-path* call rather than an occasional one — every one of potentially thousands of requests per second calls it twice (request start, response received), so its per-call cost is no longer incidental, it's directly additive to the latency the tool is trying to measure. Checking the existing design against this: the API shape itself (an opaque, cheaply-copyable `Instant`, no allocation, no `Result`) is already right for a hot path — nothing about `now()`'s signature needs to change. What the app surfaces as a genuine gap is that this module has never stated *any* cost expectation for `now()`, only its correctness properties (monotonic, non-comparable across processes). On real platforms `Instant::now()` is typically backed by a vDSO call (Linux `clock_gettime(CLOCK_MONOTONIC)` via vDSO, macOS `mach_absolute_time`, Windows `QueryPerformanceCounter`) — no kernel trap in the common case, on the order of tens of nanoseconds — which would make "thousands of calls per second" trivially cheap and not a real concern. But this module doc doesn't say that anywhere, and a stdlib that's silent on it forces every performance-sensitive caller (this app being the first to actually need the answer) to either assume it's cheap without a documented basis, or benchmark it themselves before trusting it on a hot path.
- **web-downloader / chat-server**: both need message/log timestamps (wall clock, for human-readable output) *and* elapsed-time math (ETA/throughput, idle-connection timeout) simultaneously, within the same request lifecycle — this is what confirmed both types need to coexist cleanly in one module rather than one being treated as the "main" type and the other bolted on, since a single app routinely needs both in the same code path (e.g. web-downloader logs a wall-clock timestamp per retry while computing elapsed-time backoff from an `Instant`).

## Open questions / risks
Whether `Instant` needs a documented (even if platform-varying) precision/resolution guarantee — some platforms' monotonic clocks have coarse granularity (a few milliseconds) which could matter for mp3-player's 4x/sec UI update but likely does not; this is a "should document, not redesign" risk rather than an open API question.

**Flagged, not resolved (load-tester):** `Instant::now()` has no documented cost characteristic at all — not even a "typically backed by a vDSO, expect tens of nanoseconds, not a syscall trap" note, let alone a guarantee. This project's analysis-only scope can't settle it (it's an implementation/benchmark fact, not an API-shape decision), but load-tester is the first app where the answer is load-bearing: if some target platform's `now()` implementation is a real syscall rather than a vDSO-style fast path, recording two timestamps per request at thousands of requests per second would measurably skew the very latencies the tool reports, and nothing here would have warned the implementer. Recommended next step for whoever implements this module: document the expected fast-path mechanism per target platform and, if any platform can't offer it, surface that as a documented caveat (not a different API) rather than leaving performance-sensitive callers to discover it empirically.
