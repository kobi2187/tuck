# std.async — Tuck translation

## Most of this module is the language.

`task`, `[io]` as the yield annotation, `on select` for waiting on several
events, and the scheduler itself are all built in. A Tuck author writes:

```tuck
task fetchFeed({url: str}) -> !{feed: Feed}:
  let resp = http.get {url}     # [io] → implicit yield, no await keyword
  resp.body parse

let r = {url: u} fetchFeed      # bound => awaited
{lfd: fd} serve                 # not bound => scheduled, not awaited
```

So the Nim design's `spawn`, its await mechanics, and its `Future`
vocabulary have no counterpart to write — the effect system *is* the async
annotation.

**Compiler-verified** for what remains, `./tuck ch`: `OK`.

## What's left: scope

```tuck
type Scope = {id: int, deadlineMs: u64}

pending:
  fn rootScope() -> Scope [io]
  fn childScope({parent: Scope, deadlineMs: u64}) -> Scope [io]
  fn stopScope({s: Scope}) -> void [io]
  fn isRunning({s: Scope}) -> bool [io]
  fn waitAll({s: Scope, timeoutMs: u32}) -> bool [io]
  fn sleepMs({ms: u32}) -> void [io]
```

`Scope` earns its place: structured cancellation ("stop everything under
this point") and deadlines are genuinely not in the language, and round-0's
finding #6 showed one design serves both shapes — one root scope for a
bounded batch (`web-downloader`), one child scope per connection derived
from a long-lived root (`chat-server`).

## Round-3's executor decision has to be revisited

The Nim design settled a load-bearing question in round 3: **a bounded M:N
work-stealing pool, N OS worker threads roughly matching core count**,
forced by `load-tester`'s 200 concurrent requests. The corollary was that
`AsyncMutex` is mandatory for any lock held across a suspension point,
because a blocked plain mutex parks a whole worker.

**Tuck's scheduler is single-threaded cooperative** — "no preemption, no OS
threads in the scheduler." So:

- **The `AsyncMutex` rule dissolves.** There is no worker pool to starve,
  and no second thread to contend with; `sys.sync`'s locks don't exist
  either (see that module). A task holds state until its next `[io]` point,
  and nothing else runs meanwhile. This is *simpler* than the Nim design,
  not worse.
- **`workerCount()` has no meaning** and is dropped.
- **The scalability claim changes shape but survives for I/O**: measured 32
  concurrent connections in 108ms where serial would be 3200ms, because
  sockets go through the reactor. `load-tester`'s `-c 200` is an I/O-bound
  workload, so it is served.
- **CPU-bound parallelism is genuinely unavailable.** A workload that wants
  four cores gets one. Nothing in this module can fix that; it's a language
  and runtime property.

⚠️ **Flagging this as provisional.** I'm inferring from the scheduler
description rather than from a benchmark, and the offload-worker mechanism
for blocking externs means the picture is not purely single-threaded. Worth
confirming against the runtime before treating "no CPU parallelism" as
settled.

## Notes
- **`sleepMs` is deliberately listed here as well as `sys.time`** — the
  language docs note it "is *not* offloaded: it is a reactor timer, which
  suspends only the calling task." That is async behaviour, so callers look
  for it here.
- **`Scope`-carried values (request ids, tracing context) are not
  translated** — they need a heterogeneous key/value store, which wants
  `alloc.map` (blocked) or a per-app record. Deferred.
