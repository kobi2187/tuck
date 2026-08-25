# std.perf — Tuck translation

## Shape decision
Freeform functions over plain records — no OS resource is owned, so no
actor. Per direct guidance: freeform now, may later be proxied into a
manager object (e.g. one process-wide registry held somewhere central) if a
real need surfaces.

**Compiler-verified**, `./tuck ch`: `OK`, 12/12 signatures `PENDING`, none
rejected.

**A real constraint this surfaced, bigger than `core.geom`'s:** Tuck
enforces value semantics on every parameter — a callee cannot write through
it (`TK-TY15`). The Nim design's `adjust(c: var Counter, delta)`,
`start(s: var Stopwatch)` were in-place mutators; that shape does not exist
here. Every one of these becomes "takes the old value, returns the new
one," and the caller rebinds:

```tuck
var c = {name: "restarts"} newCounter
c = {c, delta: 1} adjust        # not c.adjust(1) mutating in place
```

This is the concrete shape of the "manager object" question raised in
conversation: a single process-wide counter that many call sites touch
needs *something* holding the current value between calls — a `var` at
module scope in the calling code today; a proxy/manager object later, per
direct guidance, once that need is real rather than assumed.

## The API

```tuck
type Stopwatch = {startedAtMs: u64, running: bool}
type Counter = {name: str, value: i64}
type Histogram = {name: str}

pending:
  fn newStopwatch() -> Stopwatch
  fn start({s: Stopwatch}) -> Stopwatch
  fn stop({s: Stopwatch}) -> Stopwatch
  fn isRunning({s: Stopwatch}) -> bool
  fn elapsedMs({s: Stopwatch}) -> u64

  fn newCounter({name: str}) -> Counter
  fn adjust({c: Counter, delta: i64}) -> Counter
  fn count({c: Counter}) -> i64

  fn newHistogram({name: str}) -> Histogram
  fn addSample({h: Histogram, ms: u64}) -> Histogram
  fn percentile({h: Histogram, p: float}) -> u64
  fn meanMs({h: Histogram}) -> u64
```

## In use

```tuck
var sw = newStopwatch
sw = {s: sw} start
var c = {name: "restarts"} newCounter
c = {c, delta: 1} adjust
```

## Open questions carried over
- `elapsedMs` presupposes `Stopwatch` carries enough state (`startedAtMs`)
  to compute elapsed time without a mutable "now" reference — fine for a
  value-returning design, but the Nim original's `time()` template
  (start/run-body/stop/record in one call) has no equivalent probed here;
  Tuck templates/macros for a similar "wrap a block" ergonomic were not
  explored in this pass.
- The process-wide default registry (`list()` over every named counter in
  the Nim design) has no home in a pure value-semantics world without a
  manager object holding the table — explicitly deferred, per direct
  guidance, rather than guessed at.
