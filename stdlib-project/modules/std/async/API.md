# std.async

## Purpose
Structured concurrency for the `std` tier: tasks that cannot outlive their parent scope, a cancellation/deadline-carrying `Context` threaded explicitly through call graphs, and `select`/timeout primitives — built on `sys.thread`/`sys.sync`, not a replacement for them.

## Design lineage
Modeled on Go's `context.Context` (cancellation-as-a-value, propagated explicitly, not thread-local magic) for the context shape, and Kotlin coroutines' structured concurrency (a `CoroutineScope` cannot return until every child it launched has finished or been cancelled) for the task-lifetime shape. Explicitly rejects the "detached goroutine" pattern Go itself allows — every `std.async` task is owned by a scope so leaks are a compile-time-visible shape, not a runtime surprise.

## Proposed API
```
// Context: cancellation + deadline + typed values, propagated by value (cheap to clone, ref-counted internally)
struct Context;
impl Context {
    fn background() -> Context;
    fn with_cancel(parent: &Context) -> (Context, CancelFn);
    fn with_deadline(parent: &Context, at: sys::time::Instant) -> (Context, CancelFn);
    fn with_timeout(parent: &Context, d: core::types::Duration) -> (Context, CancelFn);
    fn with_value<T: 'static>(parent: &Context, key: &'static str, val: T) -> Context;
    fn value<T: 'static>(&self, key: &'static str) -> Option<&T>;
    fn done(&self) -> DoneSignal;              // selectable; fires on cancel or deadline
    fn err(&self) -> Option<CancelReason>;      // Cancelled | DeadlineExceeded, once done
}
type CancelFn = fn();

// Scope: the structured-concurrency boundary. Cannot return until all children join.
struct Scope<'ctx>;
impl<'ctx> Scope<'ctx> {
    fn spawn<T, F>(&self, f: F) -> TaskHandle<T>
        where F: FnOnce(Context) -> core::types::Result<T, core::error::Error> + Send + 'ctx;
}
fn scope<R>(parent: &Context, body: impl FnOnce(&Scope) -> R) -> R;
// on body return (normal or panic), scope cancels its Context and joins every outstanding child
// before returning — a child task can never outlive the `scope()` call.

struct TaskHandle<T>;
impl<T> TaskHandle<T> {
    fn join(self) -> core::types::Result<T, core::error::Error>;   // blocks until done, propagates child panic as Error
    fn cancel(&self);
}

// select over up to N ready-signals (channel recv, Context.done(), timer)
fn select(cases: &[SelectCase]) -> usize;   // index of the ready case; use per-case guards to extract values

// convenience timeout wrapper
fn timeout<T>(ctx: &Context, d: core::types::Duration,
              f: impl FnOnce(Context) -> core::types::Result<T, core::error::Error>)
              -> core::types::Result<T, core::error::Error>; // Err(DeadlineExceeded) if it fires first

// Added for kv-store-server, MADE MANDATORY GUIDANCE for load-tester — see "Executor model
// (RESOLVED, load-tester)" below. A lock that suspends the *task* on contention, not the OS
// worker thread backing it, so a hot shared-state lock doesn't starve the scheduler under many
// simultaneously-busy tasks the way a raw sys.sync::Mutex would.
struct AsyncMutex<T>;
impl<T> AsyncMutex<T> {
    fn new(value: T) -> AsyncMutex<T>;
    fn lock(&self, ctx: &Context) -> core::types::Result<AsyncMutexGuard<T>, core::error::Error>; // Err on ctx cancellation while waiting
}
struct AsyncMutexGuard<'a, T>;   // Deref/DerefMut to T; releases (and wakes the next waiting task) on drop

// Added for load-tester, alongside the executor-model resolution below — a bounded semaphore
// sized to the executor's worker-thread count, so callers can reason about "how many tasks may
// run truly concurrently" without reaching into scheduler internals.
struct Executor;
impl Executor {
    fn worker_count(&self) -> usize;   // N OS worker threads backing the current scope's tasks;
                                        // defaults to sys::thread::available_parallelism()
}
```

## Key design decisions
- **One task/context design serves both fan-out-then-done and long-lived-server shapes, but the *scope* is where they diverge, not the primitive.** `web-downloader` opens one `scope(&ctx)` for the whole batch, spawns N download tasks, and the scope call itself blocks until all finish or Ctrl-C cancels the shared `Context` — a natural fit. `chat-server` cannot use one program-lifetime scope for "thousands of connections" (a single slow client would pin the join point); instead each `accept()` spawns its own child scope whose `Context` derives from a long-lived server `Context`, so a per-connection scope join is cheap and independent while `SIGTERM` still cancels every connection at once by cancelling the root. This is a real refinement forced by comparing the two apps: the API had to make "cancel everything under me" (root fan-out) and "cancel just this leaf" (per-connection) both one line, which is why `with_cancel` returns a child `Context` rather than requiring a fresh root.
- **Cancellation is cooperative and value-based, never a forced thread kill.** A task must check `ctx.done()` or use cancellation-aware I/O (`sys.io` readers/writers accept a `Context`); this matches `web-downloader`'s requirement that Ctrl-C leave a resumable partial file rather than a truncated write mid-`fwrite`.
- **`select` is a function over an explicit case list, not a language keyword**, since `std.async` is a library, not a runtime with compiler support — this costs some ergonomics (no pattern-match sugar) but keeps `std` free of new syntax.
- Panics inside `spawn`'d tasks are caught and reported through `TaskHandle::join`'s `Result`, never silently dropped — a scope only ever fails loudly.
- **Revision (kv-store-server), stated honestly rather than asserted away:** `web-downloader` (bounded fan-out, tasks mostly waiting on network I/O) and `chat-server` (thousands of connections, almost all idle almost all the time) both exercise the `Context`/`Scope` *shape* — spawn, cancel, join — without ever putting real pressure on the scheduler underneath it, because in both apps a task is runnable (competing for a worker) only rarely. `kv-store-server` is different: every one of its thousands of connection-tasks is doing real, short, CPU-plus-lock work continuously, and every single request touches the same shared-map lock on its hot path. That is a load shape neither prior app could have found a problem with even if one existed, and this doc did not, at the time, specify what the executor underneath `spawn` actually is. That gap is closed below.

- **Executor model (RESOLVED, load-tester): `spawn` runs on a bounded M:N thread pool, not thread-per-task — and this is a real scalability decision, not a style preference.** `spawn`'s executor is specified concretely as: a fixed pool of **N OS worker threads, N ≈ `sys::thread::available_parallelism()`** (a small, bounded, core-count-scaled number — not one thread per task, not a single thread), each running a work-stealing run queue, onto which **M lightweight tasks** (arbitrarily many — hundreds, thousands) are scheduled cooperatively. A task occupies a worker only while it is actually runnable; when it awaits I/O (`sys.io` reads/writes taking a `Context`, `AsyncMutex::lock`, `select`, `timeout`) it is suspended and the worker thread is freed to run a different ready task, and a worker with no local work steals from another worker's queue rather than sitting idle. This is forced by `load-tester`'s own shape: `-c 200` (and higher) means hundreds of concurrently in-flight request/response cycles sustained for the run's whole duration, and thread-per-task at that concurrency means hundreds of live OS threads — each with its own stack (typically megabytes reserved, even if not committed), its own kernel scheduling overhead, and its own contribution to context-switch cost under a scheduler that was never designed to arbitrate between hundreds of runnable threads fairly. That is a real, measurable scalability wall (OS thread creation and context-switch cost do not scale the way lightweight-task scheduling does), not a stylistic preference between two equally-fine options — a thread-per-task design would make `load-tester -c 1000` categorically worse (and eventually simply fail to allocate more OS threads) in a way a bounded M:N pool does not. This also directly answers `web-downloader`'s and `chat-server`'s validation notes retroactively: both apps' load shapes are consistent with an M:N pool (neither ever had enough simultaneously-runnable tasks to distinguish the two models), so this resolution changes nothing about how those two apps use the API — it only fills in what was previously left unstated.
- **Corollary (RESOLVED): holding a plain `sys.sync::Mutex` across contention, or across an await point, inside a task can starve unrelated tasks on the same worker thread — so `AsyncMutex` is now MANDATORY guidance for those cases, not an optional mitigation.** Because M tasks share N worker threads cooperatively, a task that calls `sys.sync::Mutex::lock()` and blocks (the lock is contended) does not just block *itself* — it blocks the **OS worker thread** it happens to be running on, which means every other task the scheduler had queued onto that same worker (there may be many, since M ≫ N) is stalled until the lock is released, regardless of whether those other tasks have nothing to do with the lock at all. Under `load-tester`'s regime (hundreds of tasks, each doing a full request/response cycle against a handful of worker threads) this is not a theoretical edge case — it is the load pattern the design must be judged against, since a shared connection-pool structure (see `std.net-http`'s `ConnectionPool`) is exactly the kind of hot, shared, sometimes-contended state a `spawn`'d task touches on every single request. The resolved guidance, stated as a firm rule rather than a suggestion: **`sys.sync::Mutex` is safe to use inside a task only for a very short, uncontended critical section that never spans an `await`-equivalent suspension point** (a few instructions, no I/O, no nested lock acquisition that could block); **any lock that may be held across a suspension point, or that may see real contention under concurrent load, must be an `AsyncMutex`.** `AsyncMutex::lock` suspends the *task*, not the worker thread, on contention — the worker is freed immediately to run other ready tasks (its own or another worker's, via work-stealing) while the blocked task waits in the scheduler's own wait queue, so lock contention degrades throughput for the tasks actually waiting on that lock, never for unrelated tasks sharing the same worker. `std.net-http`'s `ConnectionPool` (added this round, see that module) follows this rule directly: its internal pool state is guarded by `AsyncMutex`, not `sys.sync::Mutex`, because pool checkout/return is exactly a "contended under load, and the calling task is about to await I/O anyway" case.

## Validated by applications
- **web-downloader**: single shared `Context` derived from the process's Ctrl-C signal (`sys.signal` → `Context::with_cancel`), fanned out across a `scope` with N `spawn`s bounded by a semaphore for per-host concurrency; `timeout` wraps each connection attempt for retry/backoff. This is the "one scope, N short tasks, one cancellation" shape the API was designed around first.
- **chat-server**: forced the child-scope-per-connection refinement described above; also exercises `Context::with_value` for per-connection request-scoped data (nickname, room) without a global registry lookup on every log line.
- **podcast-subscriber**: nested scopes — an outer scope per poll cycle spawning one child task per feed, each of which opens its own inner scope for concurrent episode downloads capped by a shared semaphore — validates that scopes compose without needing a different API at each nesting level.
- **log-grep**: uses `scope`+`spawn` for parallel per-file/per-chunk scanning with no cancellation needed beyond "stop early once enough matches found," exercising the "no context features actually used, still not verbose" path — a plain `scope(&Context::background(), |s| { ... })` with no context threading, confirming the trivial case stays trivial.
- **kv-store-server**: introduces the third concurrency load shape this module has seen — many *busy*, throughput-bound, short-request connections, rather than `web-downloader`'s bounded batch or `chat-server`'s many-idle-connections shape — and it does not cleanly validate the existing design the way the other two did; see the honest "Revision (kv-store-server)" note above. The one part of the shape the existing `Scope`/`Context` primitives serve straightforwardly is per-connection lifecycle: same as `chat-server`, each accepted connection gets its own child scope derived from the server's root `Context`, so `SIGTERM` still cancels every in-flight request uniformly. What's new and unresolved is the hot-path locking behavior under sustained per-request contention, addressed above with a proposed `AsyncMutex` rather than a confirmed answer.
- **image-thumbnailer**: a fourth, distinct shape from all three above — bounded-concurrency batch processing over a fixed, known-in-advance file list, closer to `web-downloader`'s "N tasks, one join point, then exit" than to either connection-server shape, and exercised the same way: one `scope` around a semaphore-bounded `spawn` per file, no long-lived state, no per-task contention on a shared lock (each task's resize/hash/write work is independent). This confirms the bounded-batch composition generalizes past network I/O to CPU-and-file-bound work with no new primitive needed.
- **load-tester**: the app that finally forces the executor-model question to an answer — see "Executor model (RESOLVED, load-tester)" above. `-c 200` fans out 200 concurrently in-flight request tasks from one `scope`, each looping "acquire pooled connection (`AsyncMutex`-guarded checkout, see `std.net-http::ConnectionPool`) → send request → record latency → release connection" for the run's configured duration, with a `select` over `Context::done()` (from `sys.signal`'s Ctrl-C) and the next-request-ready case so a graceful stop drains in-flight requests instead of severing them mid-response. This is the first app whose validating load actually distinguishes thread-per-task from a bounded M:N pool (`web-downloader` and `chat-server` both had too few simultaneously-runnable tasks to tell the difference), and the first whose hot path — connection-pool checkout under sustained contention — is exactly the shape the `AsyncMutex`-mandatory corollary above is written for. `stats::percentiles`-driven live progress (see `std.math`) runs as a low-frequency periodic task on the same scope, not on the per-request hot path, which is itself a direct consequence of the executor model: a percentile recompute cheap enough not to starve 200 request tasks sharing a handful of workers must be O(occasional), not O(per-request).

## Open questions / risks
Whether `Context::with_value` should be typed-key-based (like Kotlin's `CoroutineContext.Key`) rather than string-keyed to catch collisions at compile time is unresolved; string keys were kept here for cross-language pseudocode simplicity but risk key-collision bugs at scale.

**RESOLVED (was open through Extension rounds 1–2, closed this round by `load-tester`):** whether `spawn`'s executor is a bounded worker-thread pool (M:N) or effectively one OS thread per spawned task, and the corollary question of whether `sys.sync::Mutex` is safe to hold across contention inside a task, are no longer open. Decision: bounded M:N work-stealing pool (N ≈ core count), `AsyncMutex` mandatory for any lock held across a suspension point or under real contention, plain `sys.sync::Mutex` permitted only for short/uncontended critical sections. See "Executor model (RESOLVED, load-tester)" and its corollary under Key design decisions for the full reasoning and the `std.net-http::ConnectionPool` cross-reference. This is retained here, marked resolved rather than deleted, so the record shows the question was carried as genuinely open for two full rounds before `load-tester` supplied the forcing case that let it be answered concretely rather than asserted.
