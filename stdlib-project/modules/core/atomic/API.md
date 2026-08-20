# core.atomic

## Purpose
Atomic integer and pointer types with explicit memory-ordering parameters on every operation — the lowest-level concurrency primitive in the whole stdlib, on top of which `sys.sync`'s mutexes/channels and `sys.thread` are built.

## Design lineage
Modeled on Rust's `core::sync::atomic` (atomic types as distinct from plain integers, every load/store/RMW operation taking an explicit `Ordering` parameter) and C++'s `std::atomic` (the origin of the acquire/release/seq-cst memory-model vocabulary both languages share). The report's Part II notes that hiding memory ordering behind a single default (as several higher-level languages do, e.g. Java's `volatile` conflating several distinct guarantees under one keyword) trades away exactly the control that lock-free/real-time code needs — explicit ordering parameters are the deliberate rejection of that convenience.

## Proposed API
```
enum Ordering { Relaxed, Acquire, Release, AcqRel, SeqCst }

struct AtomicU32 { /* opaque */ }
struct AtomicI64 { /* opaque */ }
struct AtomicBool { /* opaque */ }
struct AtomicPtr<T> { /* opaque */ }

impl AtomicU32 {
    fn new(value: u32) -> Self;
    fn load(&self, order: Ordering) -> u32;
    fn store(&self, value: u32, order: Ordering);
    fn swap(&self, value: u32, order: Ordering) -> u32;
    fn compare_exchange(&self, current: u32, new: u32,
                         success: Ordering, failure: Ordering) -> Result<u32, u32>;
    fn compare_exchange_weak(&self, current: u32, new: u32,
                              success: Ordering, failure: Ordering) -> Result<u32, u32>;
    fn fetch_add(&self, value: u32, order: Ordering) -> u32;
    fn fetch_sub(&self, value: u32, order: Ordering) -> u32;
    fn fetch_and(&self, value: u32, order: Ordering) -> u32;
    fn fetch_or(&self, value: u32, order: Ordering) -> u32;
}
// AtomicI64, AtomicBool, AtomicPtr<T> mirror the same operation set.

fn fence(order: Ordering);                 // standalone memory fence, no associated value
fn compiler_fence(order: Ordering);        // ordering vs. compiler reordering only, no CPU fence
```

## Key design decisions
- Every operation takes `Ordering` explicitly with no default — a "just use SeqCst unless you know better" convenience default was considered and rejected, because it would silently make every use of this module correct-but-slow, hiding exactly the cost/correctness tradeoff that lock-free code (this module's primary audience) needs visible, per Principle 2's spirit extended to concurrency.
- `compare_exchange` and `compare_exchange_weak` are both exposed (not just the strong form) because the weak form is required for correct, efficient spin-loop CAS on architectures without a native strong CAS (notably relevant to `platform`-tier embedded targets) — collapsing them into one would force either a performance tax on weak-CAS platforms or silent incorrectness on strong-CAS-only application code assuming spurious-failure-free semantics.
- `compiler_fence` is kept distinct from `fence` because interrupt-handler code on single-core embedded targets sometimes needs to order accesses against the compiler only (no CPU-level cache/reordering concern exists at all), and folding it into `fence` would force an unnecessary hardware barrier instruction on hot ISR paths.

## Validated by applications
This module's validation is substrate-level throughout — no app in the set calls `core.atomic` directly; every one of them uses it indirectly through `sys.sync` (mutexes/channels) or `sys.thread`, or through `platform.interrupt`'s critical sections. That is itself the intended shape (Principle 1: atomics are a `core` building block, not an application-facing API), so validation here is about whether the primitives are *sufficient* for what the higher layers need to build:
- **mp3-player**: the lock-free handoff between the UI thread and the real-time audio thread ("next samples" and "seek requested" state) is exactly the kind of SPSC structure that must be built from `core.atomic` directly rather than `sys.sync::Mutex`, since a mutex acquisition on the audio thread risks the priority-inversion/glitch scenario the app profile calls out explicitly. This confirmed `AtomicPtr<T>` plus `compare_exchange` need to be sufficient to build a wait-free double-buffer swap without falling back to a lock, which the design as specified supports.
- **chat-server**: the shared room/client registry under concurrent access is implemented via `sys.sync` primitives, but connection counters and idle-timeout timestamps are natural fits for bare `AtomicU32`/`AtomicI64` without needing a full mutex — validating that `core.atomic` needs to be ergonomic enough for `sys.sync` (and occasionally application code) to reach for directly for simple counters, not only as an internal implementation detail invisible above `sys`.
- **embedded-sensor-node**: the ring-buffer write under `platform.interrupt`'s critical sections is the freestanding-target validation — no OS, no `sys.sync`, so any I2C-interrupt-vs-main-loop shared state must be coordinated through `core.atomic` (or a critical section) directly, confirming the module must work with zero OS dependency, which by construction (Tier 0) it does.

## Open questions / risks
Whether every target this stdlib claims to support actually has native atomics at every width specified (some microcontroller cores lack native 64-bit atomic RMW) is a real risk; the resolution is that `AtomicI64` must be allowed to fall back to a `platform.interrupt`-critical-section emulation on such targets, which needs to be specified as part of `platform`, not silently assumed here.
