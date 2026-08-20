# alloc.allocator

## Purpose
Defines the single `Allocator` interface every heap-using module above `core` depends on, plus a small set of built-in allocation strategies (arena/bump, fixed pool, fixed-buffer, general-purpose, system). This module is the load-bearing wall of the whole `alloc` tier: Principle 2 ("no hidden allocation below `std`") is enforced entirely through this one interface being threaded explicitly everywhere.

## Design lineage
Modeled directly on **Zig's `std.mem.Allocator`** (vtable of `alloc`/`resize`/`free` fn pointers passed as a value, no hidden global) — the report calls this "the most important thing this report borrows for the embedded-facing tiers" (REPORT.md line 47). Secondary influence: **Rust's `Allocator` trait / `GlobalAlloc`**, whose `Layout` (size+align) type this design reuses almost verbatim, and **D's `std.experimental.allocator`**, whose composable-building-block allocators (`Region`, `FreeList`, `AllocatorList`) motivate keeping strategies as separate small types rather than one configurable mega-allocator.

## Proposed API
```
struct Layout { size: usize, align: usize }

enum AllocError { OutOfMemory, InvalidLayout }

trait Allocator {
    fn alloc(&self, layout: Layout) -> Result<NonNull<u8>, AllocError>;
    fn alloc_zeroed(&self, layout: Layout) -> Result<NonNull<u8>, AllocError>;
    unsafe fn dealloc(&self, ptr: NonNull<u8>, layout: Layout);
    // in-place resize; returns Err (not a fallback allocation) if it cannot grow in place
    unsafe fn grow(&self, ptr: NonNull<u8>, old: Layout, new: Layout) -> Result<NonNull<u8>, AllocError>;
    unsafe fn shrink(&self, ptr: NonNull<u8>, old: Layout, new: Layout) -> Result<NonNull<u8>, AllocError>;
}

// -- Strategies --
struct ArenaAllocator<'buf> { .. }
impl<'buf> ArenaAllocator<'buf> {
    fn new_in(backing: &'buf mut [u8]) -> Self;                 // fixed backing, zero syscalls, embedded-safe
    fn new_growable(parent: &dyn Allocator, chunk_size: usize) -> Self; // grows by requesting chunks from parent
    fn mark(&self) -> ArenaMark;                                 // O(1) checkpoint
    fn reset_to(&mut self, mark: ArenaMark);                     // O(1) bulk free back to checkpoint
    fn reset(&mut self);                                         // O(1) bulk free of everything
}

struct PoolAllocator<const BLOCK_SIZE: usize, const COUNT: usize> { .. }
impl<const B: usize, const N: usize> PoolAllocator<B, N> {
    fn new_in(backing: &mut [u8; B * N]) -> Self;                // compile-time sized, no heap fallback ever
    fn try_alloc(&self) -> Result<NonNull<u8>, AllocError>;      // bounded worst-case time, never blocks
}

struct FixedBufferAllocator<'buf> { .. }                        // linear bump over caller buffer; alloc() errors (never panics/grows) on exhaustion
struct GeneralPurposeAllocator { .. }                            // freelist/buddy over SystemAllocator; debug builds add leak + double-free + use-after-free detection (Zig GPA-inspired)
struct SystemAllocator;                                          // thin malloc/free wrapper; only compiled in when a `sys` target is present

// -- Secure memory (see Key design decisions) --
struct SecureAllocator<'inner> { inner: &'inner dyn Allocator } // zeroes on dealloc/shrink; mlock/VirtualLock-backed on hosted targets, zero-only on freestanding
struct Secret<T> { .. }                                          // owns a value allocated via SecureAllocator; Drop always zeroes, Debug/Display redacted

// -- Default-allocator ergonomics --
fn set_default_allocator(a: &'static dyn Allocator);             // called once at process/firmware startup
fn default_allocator() -> &'static dyn Allocator;                // panics (or const-errors on freestanding) if never set
```

## Key design decisions
- **No implicit global, but one explicit hook.** Unlike C's ambient `malloc`, there is no allocator until `set_default_allocator` is called once — but every collection's `T::new()` convenience constructor reads that single hook, so "just give me a `Vec`" stays one line on hosted targets (`std` sets it to `SystemAllocator` automatically at process start) while embedded targets are *forced* to make a conscious choice (typically `ArenaAllocator::new_in(&mut STATIC_ARENA)`) or get a hard failure instead of silently touching a heap that was never mapped. This is the resolution to the "hide vs. expose" tension: hidden by default *where an OS makes that safe*, always overridable, never hidden by construction.
- **`grow`/`shrink` never fall back silently.** A `PoolAllocator` or `ArenaAllocator` that cannot satisfy a request returns `AllocError::OutOfMemory` rather than the module reaching for a global allocator behind the caller's back — this is the concrete mechanism that makes mp3-player's and embedded-sensor-node's "fail loudly, never silently degrade to malloc" requirement a property of the interface itself, not a caller convention that's easy to violate.
- **Secure memory is a generic capability at this tier, not forked into `alloc.string`.** `secrets-vault` raises the question of zero-on-drop, non-swappable memory directly. The position taken here: add `SecureAllocator` (wraps any allocator, zeroes on free, `mlock`s on hosted targets) and a thin `Secret<T>` wrapper, both in `alloc.allocator` — *not* a parallel `SecureString`/`SecureVec` type. `alloc.string`/`alloc.vec` already accept any `&dyn Allocator`, so `Secret<String>` and `Secret<Vec<u8>>` fall out for free by constructing the string/vec with a `SecureAllocator` and wrapping it; `std.crypto` reuses the same `Secret<T>` for key material instead of inventing its own. One mechanism, composes uniformly (Principle 4), instead of a special-cased string type only `std.crypto` knows about.
- **Strategies are separate small types, not one configurable class.** Following D's Phobos rather than a single "allocator with fifteen flags" — `ArenaAllocator` and `PoolAllocator` don't share a base implementation, only the trait, so each stays auditable and each can be `const`/compile-time-sized independently (embedded-sensor-node's requirement).

## Validated by applications
- **mp3-player**: the audio callback thread needs `PoolAllocator`'s `try_alloc` — bounded, non-blocking, and it *must* return `AllocError` rather than silently falling through to `GeneralPurposeAllocator` when the pool is exhausted, since a malloc stall on that thread is an audible glitch. This forced `grow`/`alloc` to be `Result`-returning rather than infallible-with-panic (a panic on the audio thread is as bad as a stall) — an early draft had `alloc() -> NonNull<u8>` that aborted on failure; that was rejected specifically because of this app.
- **embedded-sensor-node**: needs `ArenaAllocator::new_in` over a `static mut` buffer sized at compile time, with genuinely zero path to `SystemAllocator` (which shouldn't even link on this target). This validated that `SystemAllocator` must be conditionally compiled out rather than merely "unused," so a freestanding build can't accidentally pull in a libc allocator through a transitive dependency.
- **secrets-vault**: the direct forcing function for `SecureAllocator`/`Secret<T>` above; without it, the app would either roll its own `mlock` wrapper (contradicting Principle 4) or leave plaintext passphrases in freely-swappable, non-zeroed heap memory.
- **embedded-display-node**: a second, deliberately-different embedded validation case, chosen specifically to check whether the arena design generalizes beyond `embedded-sensor-node`'s use (small sensor-reading/ADC buffers) to a structurally different fixed-size allocation — a display framebuffer, whose size is a compile-time function of panel resolution and bit depth (e.g. a 200×200 1-bit e-ink buffer is exactly 5000 bytes, known at compile time, never resized at runtime). `ArenaAllocator::new_in` over a `static mut` backing buffer sized via a `const` expression already covers this with no change: the framebuffer is allocated once at boot, lives for the process's/firmware's entire lifetime, and is never freed or grown, which is `ArenaAllocator`'s simplest possible usage pattern (no `mark`/`reset_to` checkpointing even needed, unlike `embedded-sensor-node`'s per-sample-cycle arena reuse). This is a useful negative result: the design doesn't need a distinct "static buffer" allocator type separate from `ArenaAllocator` for the single-allocation-for-program-lifetime case.

## Open questions / risks
- `grow`/`shrink` being separate from `alloc`+`dealloc` mirrors Rust's newer `Allocator` trait but is more API surface than Zig's single `resize`; worth revisiting if implementers find the four-method trait burdensome for the common `GeneralPurposeAllocator`/`SystemAllocator` cases (a default trait-method implementation in terms of alloc+copy+dealloc mitigates this).
- `mlock`/`VirtualLock` availability and page-size granularity differ enough across POSIX/Windows/embedded that `SecureAllocator`'s "non-swappable" guarantee needs an explicit capability query (`SecureAllocator::is_lock_backed() -> bool`) so callers on unsupported platforms get an honest degraded-to-zero-only answer instead of a false sense of security.
