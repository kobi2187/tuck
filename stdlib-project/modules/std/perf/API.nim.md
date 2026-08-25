# std.perf — Nim API

## Purpose
Answer "where did the time go" and "how many of X happened" without leaving
the process — a stopwatch, a counter, and a latency histogram. Sampling
profilers, flamegraphs, and OS-specific perf-counter integration (Linux
`perf`, Windows ETW, macOS Instruments) are deliberately not here; those stay
external, per `GOVERNANCE.md`'s split.

*New in this pass.* `COMPARISON.md` found no `profile`/`trace`/metrics
surface anywhere in the 65; `GOVERNANCE.md` resolved the shape (basic
measurement at rung A, heavy tooling at rung B) against .NET's
`System.Diagnostics.Stopwatch` (in-box) versus APM tooling (not), and Go's
own `runtime/pprof` (measurement is std) versus `go tool pprof` (shells out
to Graphviz, external). This module is the measurement half only.

## Protocols implemented
`Stopwatch` is `Lifecycle` (`start`/`stop`) — timing a span is exactly
"turn it on, turn it off." `Counter` is `Adjustable`. `Histogram` is
`Collection[Duration]` in the loose sense `std.math::TDigest` already
established for a structure you feed samples into and later summarize
rather than enumerate.

## The API

```nim
type
  Stopwatch* = object          ## Lifecycle
  Counter* = object            ## Adjustable
  Histogram* = object          ## Collection-shaped: add() feeds it, summarize() reads it

proc newStopwatch*(): Stopwatch    ## constructed stopped; `start` arms it
proc start*(s: var Stopwatch): bool
proc stop*(s: var Stopwatch): bool
proc isRunning*(s: Stopwatch): bool
func elapsed*(s: Stopwatch): Duration
  ## Valid while running (time-so-far) and after `stop` (total span) alike —
  ## one call answers both questions a caller actually has, rather than a
  ## `stop()` that also has to return the duration and a separate `elapsed()`
  ## that only works one of the two ways.

template time*(name: static string; body: untyped)
  ## `time("decode"): parseFrame(buf)` — starts a stopwatch, runs `body`,
  ## stops it, and records the span into that name's counter in the
  ## process-wide default registry. The zero-ceremony path for "how long
  ## does this block take", the same shape `std.testing::benchmark` already
  ## gives a test body.

proc newCounter*(name: string): Counter
proc adjust*(c: var Counter; delta: int64)   ## the `Adjustable` verb; negative decrements
proc count*(c: Counter): int64

proc newHistogram*(name: string): Histogram
proc add*(h: var Histogram; sample: Duration)
func count*(h: Histogram): int64
func percentile*(h: Histogram; p: float): Duration
  ## p50/p95/p99 in one call, `std.math::TDigest`-backed — this module
  ## doesn't reimplement quantile estimation, it wraps the one already
  ## proven correct for `load-tester`'s streaming, non-cloneable samples.
func mean*(h: Histogram): Duration

iterator list*(): (string, Counter)
  ## Every named counter registered process-wide, for a `/metrics`-style
  ## endpoint or a shutdown summary — the `Collection` primitive over the
  ## default registry, not over one histogram's own samples.
```

## Friendly-naming notes

| Precedent (.NET/Go) | Nim name | Why |
|---|---|---|
| `Stopwatch.StartNew()` + `.Elapsed` | `newStopwatch()` + `start`/`elapsed` | `Lifecycle`'s ordinary verbs instead of a static factory that also starts the clock |
| `Stopwatch.ElapsedMilliseconds` (int) vs `.Elapsed` (TimeSpan) — two properties | `elapsed(s): Duration` | one call, one type; `sys.time::Duration` already has `asSeconds`/etc. if a caller wants a bare number |
| `metrics.Counter.Inc()` / `.Add(n)` | `adjust(c, delta)` | one verb per the closed vocabulary instead of two names for the same operation |
| Prometheus `Histogram` + separate quantile library | `Histogram` + `percentile(h, p)` | one type; the quantile math is `std.math::TDigest` reused, not reinvented |
| `using (var _ = Stopwatch.StartNew()) { ... }` (manual dispose pattern) | `time("name"): body` | a template does the start/stop/record in one line, no manual disposal to forget |

## In use

```nim
# any server (per DOMAINS.md's web-backend persona): time the hot path, expose it later
time("handle_request"):
  let rows = db.query("select * from tasks where done = ?", @[false])
  for row in rows.list(): render(row)

# process-supervisor: count restarts, no new subsystem for it
var restarts = newCounter("child_restarts")
onCrash: restarts.adjust(1)

# load-tester: the exact TDigest reuse GOVERNANCE.md's split already assumed
var latency = newHistogram("request_latency")
# ...inside the request loop...
latency.add(elapsed)
echo "p50=", latency.percentile(0.50), " p99=", latency.percentile(0.99)
```

## Vocabulary exceptions
- **`time` is a template, not a proc taking a closure.** Same reasoning
  `sys.sync::use`/`read` already state: a captured closure allocates, and
  the whole point of this module is measuring the hot path without adding
  cost to it.
- **The default registry (`list()` with no argument) is process-global,
  deliberately.** A per-thread or per-scope registry is a real, heavier
  design this module doesn't attempt — `std.log`'s sink model already shows
  what that would look like if a validated app ever needs it; none has yet.
- **Left unresolved, on purpose.** Exporting counters/histograms in a
  specific wire format (Prometheus text, StatsD) is explicitly out of this
  module — `std.encoding` or a rung-B/C package formats what this module
  measures, the same "measurement in the box, presentation not" split
  `GOVERNANCE.md` already drew from Go's `pprof`/`go tool pprof` precedent.
