# alloc.deque

## Purpose
A double-ended queue backed by a growable ring buffer — efficient push/pop at both ends, the right default for queues, sliding windows, and bounded-history buffers that `alloc.vec` handles poorly (O(n) front-removal).

## Design lineage
Modeled on **Rust's `VecDeque<T>`** (single contiguous ring buffer with wraparound indices, not a deque-of-chunks) for its cache-friendliness and simplicity, with **C++'s `std::deque`** consulted and explicitly *not* followed for its default chunked-storage design — the report's survey (Part II, composability discussion) favors the simpler, more predictable single-buffer model unless a specific app profile demands stable references across growth, which none surveyed did.

## Proposed API
```
struct Deque<T> { .. }   // ring buffer over a single allocation

impl<T> Deque<T> {
    fn new() -> Self;
    fn new_in(a: &dyn Allocator) -> Self;
    fn with_capacity_in(n: usize, a: &dyn Allocator) -> Self;

    fn push_front(&mut self, v: T) -> Result<(), AllocError>;
    fn push_back(&mut self, v: T) -> Result<(), AllocError>;
    fn pop_front(&mut self) -> Option<T>;
    fn pop_back(&mut self) -> Option<T>;
    fn front(&self) -> Option<&T>;
    fn back(&self) -> Option<&T>;

    fn len(&self) -> usize;
    fn is_full(&self) -> bool;                          // meaningful for fixed-capacity mode below
    fn get(&self, index: usize) -> Option<&T>;           // logical index, 0 = front
    fn iter(&self) -> core.iter::Iter<&T>;               // front-to-back order
    fn allocator(&self) -> &dyn Allocator;
}

// Bounded/ring-buffer mode: never grows past capacity, overwrites or rejects instead
enum OverflowPolicy { Reject, OverwriteOldest }
impl<T> Deque<T> {
    fn with_fixed_capacity_in(n: usize, policy: OverflowPolicy, a: &dyn Allocator) -> Self;
}
```

## Key design decisions
- **Single ring buffer, not a deque-of-chunks.** Simpler invariants, one allocation to reason about for embedded/pool-allocator use, and better cache behavior for the sequential-scan-heavy access patterns the surveyed apps actually have; the chunked-deque design's main advantage (stable element references across `push_front`/`push_back`) wasn't needed by any app profile, so it's not paid for.
- **A fixed-capacity, non-growing mode is a first-class constructor, not a workaround.** `with_fixed_capacity_in` with `OverwriteOldest` gives a genuine bounded ring buffer (fixed memory, O(1) always, never calls the allocator again after construction) rather than making every embedded/real-time caller build one out of the growable variant by discipline — this directly answers embedded-sensor-node's ring-buffer-of-samples requirement and mp3-player's need for a bounded scratch structure that can share space with a `PoolAllocator`.
- **`OverflowPolicy::Reject` vs `OverwriteOldest` is chosen at construction, not per-call**, so the caller's intent ("this is a log that drops oldest data" vs. "this must never silently lose data") is visible in one place rather than scattered across every `push` call site as an `if`.
- **Allocator-parameter pattern identical to `alloc.vec`/`alloc.map`** — by this point in the tier, the convention (`new()` default, `new_in(&a)` explicit, `with_capacity_in` combining both) should be entirely predictable to a caller who has used any other `alloc` collection, which is itself a design goal (Principle 4 extended to allocator ergonomics as its own cross-cutting concern).

## Validated by applications
- **embedded-sensor-node**: the sample ring buffer logged to flash is exactly `Deque::with_fixed_capacity_in(n, OverwriteOldest, &arena)` — fixed at compile time, never touches an allocator again after init, and the wear-conscious flash-writing behavior (avoid rewriting the same sector every sample) is layered by `platform.boot`/flash driver code *on top of* this deque's `pop_front`/`push_back`, not reimplemented inside it. This validated that the fixed-capacity mode needed to exist as a distinct constructor rather than "just set `with_capacity` and never call push past that" — the latter gives no compile/construction-time signal that growth was never intended.
- **mp3-player**: playlist next/prev navigation is naturally a deque-like access pattern (advance from the front, occasionally push a "play next" request to the front for override) — a good fit, though this app's *actual* hot-path handoff between UI and audio threads is explicitly `sys.sync`'s job (a lock-free SPSC queue), not this module; the app profile is a useful negative validation that `alloc.deque` is for single-threaded/UI-side queuing, not the real-time cross-thread path, and the two shouldn't be conflated.
- **podcast-subscriber** / **web-downloader**: the download queue under a concurrency cap (N in flight, rest waiting) is a `Deque<DownloadTask>` with `pop_front` feeding available worker slots and `push_back` enqueuing newly-discovered episodes — ordinary FIFO usage that surfaced no new requirements, a useful confirmation that the plain growable mode is sufficient for this common shape without needing the fixed-capacity variant.

## Open questions / risks
- Whether `OverwriteOldest` should return the overwritten element (so callers can, e.g., flush it to flash before it's lost) rather than silently dropping it is open — embedded-sensor-node's flash-logging use case plausibly wants this (`push_back_evicting(&mut self, v: T) -> Option<T>`), and the current `OverflowPolicy` design doesn't yet expose that value; likely needed before this module can be called final for that app.
