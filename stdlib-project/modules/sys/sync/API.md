# sys.sync

## Purpose
Cross-thread coordination primitives: `Mutex`, `RwLock`, condition variables, one-shot `Once` initialization, a rendezvous `Barrier`, and mpsc/mpmc channels — the toolkit for safely sharing state or handing off data between `sys.thread` threads.

## Design lineage
Modeled on Rust's `std::sync` (data-carrying `Mutex<T>` that owns its guarded value, rather than a bare lock object guarding nothing) combined with Rust's `std::sync::mpsc`/crossbeam-style channels for message passing, and Go's `sync` package for `Once`/`WaitGroup`-equivalent shapes; C++'s `std::mutex`/`condition_variable` is the POSIX-adjacent reference point for the condvar API shape specifically. The data-owning `Mutex<T>` (rather than C++/POSIX's "lock this handle, separately touch that data, hope you remembered to lock first") is the single biggest ergonomic and safety departure from the older models.

## Proposed API
```
struct Mutex<T> { .. }
impl<T> Mutex<T> {
    fn new(value: T) -> Mutex<T>;
    fn lock(&self) -> Result<MutexGuard<T>, PoisonError>;       // blocks; guard derefs to &mut T
    fn try_lock(&self) -> Result<MutexGuard<T>, TryLockError>;
}
struct RwLock<T> { .. }
impl<T> RwLock<T> {
    fn new(value: T) -> RwLock<T>;
    fn read(&self) -> Result<RwLockReadGuard<T>, PoisonError>;
    fn write(&self) -> Result<RwLockWriteGuard<T>, PoisonError>;
}

struct Condvar { .. }
impl Condvar {
    fn new() -> Condvar;
    fn wait<'a, T>(&self, guard: MutexGuard<'a, T>) -> Result<MutexGuard<'a, T>, PoisonError>;
    fn wait_timeout<'a, T>(&self, guard: MutexGuard<'a, T>, dur: Duration) -> Result<(MutexGuard<'a, T>, WaitTimeoutResult), PoisonError>;
    fn notify_one(&self);
    fn notify_all(&self);
}

struct Once { .. }
impl Once { fn new() -> Once; fn call_once<F: FnOnce()>(&self, f: F); }

struct Barrier { fn new(n: usize) -> Barrier; fn wait(&self) -> BarrierWaitResult; }

fn channel<T: Send>() -> (Sender<T>, Receiver<T>);              // mpsc, unbounded
fn sync_channel<T: Send>(bound: usize) -> (SyncSender<T>, Receiver<T>);  // bounded, backpressure via send blocking
impl<T> Sender<T> { fn send(&self, v: T) -> Result<(), SendError<T>>; }
impl<T> Receiver<T> {
    fn recv(&self) -> Result<T, RecvError>;
    fn try_recv(&self) -> Result<T, TryRecvError>;
    fn recv_timeout(&self, dur: Duration) -> Result<T, RecvTimeoutError>;
}

// Lock-free single-producer/single-consumer, no allocation on the steady-state path:
struct SpscRing<T, const N: usize> { .. }
impl<T, const N: usize> SpscRing<T, N> {
    fn split(self) -> (SpscProducer<T, N>, SpscConsumer<T, N>);
}
impl<T, const N: usize> SpscProducer<T, N> { fn try_push(&mut self, v: T) -> Result<(), T>; }  // never blocks
impl<T, const N: usize> SpscConsumer<T, N> { fn try_pop(&mut self) -> Option<T>; }              // never blocks
```

## Key design decisions
- `Mutex<T>`/`RwLock<T>` own the data they guard rather than being bare OS lock handles — this makes "forgot to lock before touching shared state" a compile-time impossibility instead of a runtime race, the single most consequential design choice in this module and a direct application of Principle 3 (the guard is itself a minimal composable handle: derefs to `&T`/`&mut T`, nothing else).
- Lock methods return `Result<_, PoisonError>` rather than an infallible guard — if a thread panics while holding the lock, later lockers are told explicitly (poisoning) rather than silently observing a possibly-inconsistent value, matching `core.error`'s uniform error idiom instead of inventing a lock-specific failure mode.
- `SpscRing` is a distinct, separate type from `Mutex`/channels, not a "fast path" flag on the general channel — its `try_push`/`try_pop` are documented as *never blocking and never allocating*, a fundamentally different contract from `channel()`'s `send`/`recv`, which real-time code must be able to select at the type level rather than trust a runtime configuration to honor.
- Bounded (`sync_channel`) and unbounded (`channel`) are separate constructors rather than one channel type with an optional capacity — an unbounded channel silently growing under backpressure is a real production failure mode (chat-server's slow-client case) that the type-level split makes visible in the calling code rather than a tunable default.

## Validated by applications
- **mp3-player**: this app is the direct forcing function for `SpscRing` existing at all — a naive first design offered only `Mutex`-guarded shared state for "next samples"/"seek requested" handoff between the UI and audio threads, but a `Mutex` acquired from the audio callback risks priority inversion and unbounded wait time (an audible glitch). The refined design adds a genuinely lock-free, zero-allocation-on-steady-state SPSC ring specifically because the app's stated constraint ("no fallback to blocking on the hot path") cannot be met by `Mutex`/`Condvar` alone, confirming `sys.sync` needs more than "a generic Mutex" to be a real answer for real-time code.
- **chat-server**: the shared room/client registry accessed concurrently from many per-connection handlers is the primary test of `Mutex<T>`/`RwLock<T>` under genuine contention — this is explicitly called out as testing "whether `sys.sync`'s primitives are fast enough under contention to avoid needing a bespoke lock-free structure." `RwLock` earns its place in the API specifically because room broadcast (many concurrent readers listing room membership) alongside occasional join/leave writes is a textbook read-heavy/write-rare pattern that a plain `Mutex` would serialize unnecessarily.
- **log-grep**: parallel scan across files/chunks with "a shared result-aggregation point" is naturally served by `sync_channel`/`channel` (each worker thread sends its per-chunk matches back to a collector) rather than a shared `Mutex<Vec<Match>>` — confirming channels, not just locks, need to be first-class in `sys.sync` rather than relegated to a `std`-tier convenience, since this is exactly the fan-out/fan-in shape channels are best suited for.
- **kv-store-server** (Round 2): a deliberately different contention shape than `chat-server`'s. `chat-server` validated `Mutex<T>`/`RwLock<T>` against *many idle connections* — lock acquisitions are comparatively rare relative to wall-clock time, and `RwLock` earns its keep because the read case (broadcast/room-membership listing) dominates. kv-store-server is *many busy connections*, throughput-bound: every single `GET`/`SET`/`DEL`/`INCR` on the hot path touches the shared map, so the map's lock is acquired far more often per second, and unlike chat-server's workload, writes (`SET`/`DEL`/`INCR`/active TTL expiry) are not rare relative to reads (`GET`) — a workload `RwLock` alone does not specially help with, since a write-heavy `RwLock` degrades toward the same effective serialization as a plain `Mutex`. Checking whether the existing primitives hold up: they do, but only if the app shards — partitioning the map into N independent `Mutex<HashMap<K,V>>` (or `RwLock<..>>`) instances keyed by `hash(key) % N`, so unrelated keys never contend for the same lock. This requires no new `sys.sync` primitive: an array of `Mutex<T>` (or `RwLock<T>`) already expresses it, and `alloc.map` doesn't need a bespoke "concurrent map" type either — sharding is a composition pattern built entirely from what this module already exposes. Recorded as a design pattern this module's docs should surface (see Open Questions), not as an API change.

## Open questions / risks
**Gap noted (not resolved here):** kv-store-server's throughput-bound shape validates that `Mutex`/`RwLock` are *sufficient* building blocks for sharded locking, but the module currently offers no convenience for the sharding pattern itself (e.g., a `ShardedMap<K, V>` that hashes a key to the right shard's lock internally) — every app that wants this has to hand-roll the `hash(key) % N` indexing and the `Vec<Mutex<HashMap<K,V>>>` bookkeeping. That convenience, if it's worth adding at all, more naturally belongs in `alloc.map` (it's a map-shaped API wrapping `sys.sync` primitives, not a new synchronization primitive) than here — noted for whoever next touches `modules/alloc/map/API.md`, not resolved in this module.
Whether `PoisonError` recovery (`into_inner()` to force-unlock a poisoned mutex and accept possibly-inconsistent data) belongs in `sys.sync` itself or is dangerous enough to push entirely to an explicit, loudly-named escape hatch — Rust's own experience with poisoning being more annoying than protective in practice for some use cases is a live debate this design inherits rather than resolves.
