# sys.thread

## Purpose
Wraps native OS threads: spawning with a closure/stack-size configuration, joining, and thread-local storage — the substrate `sys.sync` primitives and `std.async`'s executor are built on.

## Design lineage
Modeled on Rust's `std::thread` (typed `JoinHandle<T>` carrying the closure's return value, builder for stack size/name) over raw POSIX pthreads (rejected as the primary model because `pthread_create`'s `void*`-in/`void*`-out signature discards type safety that a modern stdlib shouldn't reintroduce) and C++'s `std::thread` (closer in spirit but its `detach()`-by-default-if-forgotten footgun is deliberately not replicated — a `JoinHandle` that's dropped without joining is a compile-time-detectable resource leak here, not silent detachment).

## Proposed API
```
struct Builder { .. }
impl Builder {
    fn new() -> Builder;
    fn name(self, name: &str) -> Builder;
    fn stack_size(self, bytes: usize) -> Builder;
    fn spawn<F, T>(self, f: F) -> Result<JoinHandle<T>, ThreadError>
        where F: FnOnce() -> T + Send + 'static, T: Send + 'static;
}
fn spawn<F, T>(f: F) -> JoinHandle<T>
    where F: FnOnce() -> T + Send + 'static, T: Send + 'static;   // Builder::new().spawn().unwrap() convenience

struct JoinHandle<T> { .. }
impl<T> JoinHandle<T> {
    fn join(self) -> Result<T, ThreadPanic>;    // blocks; Err if the thread panicked, carrying the payload
    fn is_finished(&self) -> bool;
    fn thread(&self) -> ThreadRef;              // id/name accessor, no ownership
}

fn current() -> ThreadRef;
fn sleep(dur: Duration) -> ();          // dur from sys.time, not a raw integer — no ambiguous units
fn yield_now();
fn available_parallelism() -> Result<usize, ThreadError>;   // hint for worker-pool sizing

struct LocalKey<T> { .. }               // thread-local storage, declared statically
impl<T: 'static> LocalKey<T> {
    fn with<F, R>(&'static self, f: F) -> R where F: FnOnce(&T) -> R;
}
// usage: static COUNTER: LocalKey<Cell<u32>> = thread_local_init!(|| Cell::new(0));
```

## Key design decisions
- `JoinHandle<T>` is generic over the closure's return type and must be explicitly joined or explicitly detached (`handle.detach()`, a distinct opt-in call, not shown above but present) — a `JoinHandle` silently dropped is flagged by `core.error`'s contract-checking machinery as a leak in debug builds, closing off C++'s "forgot to join or detach" footgun by construction rather than by convention.
- `sleep` takes `sys.time::Duration`, not a bare integer, so "sleep(500)" can never be ambiguous between milliseconds and seconds across call sites — a direct application of Principle 4 (one coherent idiom, here for durations specifically) even though `Duration` itself lives in `sys.time`.
- Thread panics are captured and returned from `join()` as data (`Result<T, ThreadPanic>`) rather than being allowed to silently terminate the process or silently vanish — matches `core.error`'s Result-carried-errors idiom applied to the one case (a panic on another stack) that can't naturally propagate as a return value.
- `available_parallelism()` is fallible (cgroup/container CPU quotas can make this genuinely unknowable) rather than an infallible function that silently falls back to `1`, so callers sizing a thread pool see the uncertainty rather than getting a plausible-looking wrong number.

## Validated by applications
- **mp3-player**: the dedicated real-time audio-output thread, separate from the UI/input thread, is this module's sharpest test — the requirement that the audio thread "never block on the general-purpose allocator or a contended lock" pushed the design toward `Builder::stack_size` being mandatory-considered (a fixed, pre-sized stack for the audio thread, no dynamic growth surprises) and confirmed that `sys.thread` itself needs to add nothing audio-specific — the real-time constraints live entirely in what the app does *inside* the thread (via `sys.sync`'s lock-free handoff and `alloc.allocator`'s fixed pool), not in `sys.thread`'s spawn/join API, which is a useful negative finding.
- **chat-server**: thread-per-connection is offered as "a real comparison point" against `std.async`'s task model. This is why `spawn`'s closure bound is `Send + 'static` with no additional lifetime gymnastics — thousands of short-lived per-connection threads must be spawnable from a hot accept-loop without the app fighting the borrow checker over shared state (which instead flows through `sys.sync::Arc<Mutex<Registry>>`-shaped types). It also surfaced that `available_parallelism()` matters less here than expected, since a naive thread-per-connection design doesn't size a pool by CPU count at all — a real finding about which apps actually need that function.
- **log-grep**: parallel scan across files/chunks is a classic fork-join shape (spawn N worker threads, `join()` each, aggregate results) rather than a long-lived-connection shape — this confirmed `JoinHandle<T>`'s typed return value is essential (each worker thread's `join()` yields its match-count/results directly) rather than requiring a shared mutable output structure guarded by `sys.sync`, which was the naive first design and is strictly worse for this access pattern.

## Open questions / risks
Whether `sys.thread` should expose thread priority / CPU-affinity hints (relevant to the mp3-player's real-time thread wanting elevated scheduling priority on platforms that support it) — currently absent from the sketch above and likely needed as an opt-in, platform-conditional extension rather than a portable guarantee, since not all OSes expose the same priority model.
