# core.ptr

## Purpose
Raw pointer arithmetic and validity primitives for the small set of modules that legitimately need them (allocators, FFI boundaries, MMIO/hardware register access, `core.slice`'s internals) — deliberately not meant for everyday application code, which should stay on `Slice`/references.

## Design lineage
Modeled on Rust's `core::ptr` (explicit `read`/`write`/`copy` functions instead of C's implicit pointer-dereference-and-arithmetic-everywhere, plus `NonNull<T>` for the common "never null" pointer case) and C's pointer model as the thing being deliberately constrained rather than copied — the report's Part II ties raw, unconstrained pointer arithmetic directly to the C/C++ defect categories (use-after-free, buffer overrun) that every other systems language in the survey (Rust, Zig, even modern C++ guidance) has moved away from without removing pointers outright.

## Proposed API
```
struct Ptr<T> { /* opaque, raw address, possibly null */ }
struct NonNull<T> { /* opaque, raw address, statically never null */ }

impl<T> Ptr<T> {
    fn null() -> Self;
    fn is_null(&self) -> bool;
    unsafe fn offset(self, count: isize) -> Self;      // pointer arithmetic, unchecked
    unsafe fn add(self, count: usize) -> Self;
    unsafe fn read(self) -> T;                          // bitwise-copy load
    unsafe fn write(self, value: T);                    // bitwise-copy store, no drop of old value
    unsafe fn read_volatile(self) -> T;                 // for MMIO: forbids reorder/elision
    unsafe fn write_volatile(self, value: T);
    fn cast<U>(self) -> Ptr<U>;
}

impl<T> NonNull<T> {
    fn new(ptr: Ptr<T>) -> Option<NonNull<T>>;
    unsafe fn new_unchecked(ptr: Ptr<T>) -> NonNull<T>;
    fn as_ptr(self) -> Ptr<T>;
}

unsafe fn copy<T>(src: Ptr<T>, dst: Ptr<T>, count: usize);          // may overlap
unsafe fn copy_nonoverlapping<T>(src: Ptr<T>, dst: Ptr<T>, count: usize);
```

## Key design decisions
- Every dereferencing/arithmetic operation is `unsafe` and a named function (`read`, `write`, `offset`), never an overloaded `*`/`[]`/`+` operator — this makes every raw-pointer operation textually greppable and audit-friendly across a codebase, a direct response to C/C++'s implicit-everywhere pointer semantics that the report flags.
- `read_volatile`/`write_volatile` are separate from `read`/`write`, not a flag, because MMIO correctness depends on the compiler never reordering, coalescing, or eliding volatile accesses — conflating the two was rejected early since a single `read(ptr, volatile: bool)` signature would still let an optimizer see through a non-constant flag in ways a dedicated intrinsic-backed function does not.
- `NonNull<T>` exists as a distinct type (not just documentation convention) so that FFI signatures and allocator internals can express "never null" in the type system, letting `Option<NonNull<T>>` niche-optimize to the same size as a raw pointer — directly reusing `core.types`' niche-filling approach to `Option`.

## Validated by applications
- **embedded-sensor-node**: this is the direct, substrate-level validation — MMIO register access (I2C peripheral control, GPIO for the status LED) is only expressible through raw pointers to fixed hardware addresses, and `read_volatile`/`write_volatile` are non-negotiable for correctness (a naive `read`/`write` here would let the optimizer legally elide a "redundant-looking" register write that actually toggles a physical pin). This app is where the volatile/non-volatile split earns its keep; without it, register access code would need target-specific compiler-barrier workarounds outside the type system.
- **mp3-player**: `sys.ffi` calling into a C decoding library needs `core.ptr` as the interop substrate — buffers handed to and received from the C decoder are raw pointers with C-side-managed lifetimes that don't fit `Slice`'s borrow-checked model. `cast` and `NonNull` are what let the FFI boundary code stay narrowly scoped (one small module wrapping the unsafe pointer traffic) rather than leaking raw pointer types into the rest of the audio pipeline, which uses `Slice` everywhere else.
- **archive-cli**: mostly indirect — `core.ptr` underlies `sys.io`'s streaming compression buffers and `alloc.vec`'s internal growth logic, neither of which the app touches directly, but both of which must be correct for `archive-cli`'s "streaming create/extract, don't require the whole archive in memory" requirement to hold without corrupting data on buffer reallocation.

## Open questions / risks
How much of this module's `unsafe` surface should be reachable from ordinary application code at all (versus being an implementation-detail dependency only `alloc`/`sys`/`platform` internals use) is a documentation and tooling question more than an API one — flagged for the top-level architecture doc to resolve with a visibility/lint convention.
