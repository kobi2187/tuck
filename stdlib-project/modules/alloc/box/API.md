# alloc.box

## Purpose
Unique heap ownership of a single value — the mechanism for putting one thing on the heap (large stack-unfriendly values, recursive types, or trait-object/dynamic-dispatch indirection) without the overhead or shared-ownership semantics of `alloc.rc`.

## Design lineage
Modeled on **Rust's `Box<T>`** (move-only, `Deref`/`DerefMut` to `T`, drops and deallocates on scope exit, doubles as the standard way to hold a trait object `Box<dyn Trait>`) and **C++'s `std::unique_ptr`** for the RAII-ownership-transfer story (move semantics, no copy constructor). This is the simplest module in the tier by design — a thin allocator-backed wrapper — and its API surface reflects that: no growth, no capacity, no iteration.

## Proposed API
```
struct Box<T: ?Sized> { .. }

impl<T> Box<T> {
    fn new(value: T) -> Result<Self, AllocError>;                 // default allocator
    fn new_in(value: T, a: &dyn Allocator) -> Result<Self, AllocError>;
    fn into_inner(self) -> T;                                     // move value out, deallocate the box
    fn allocator(&self) -> &dyn Allocator;
}

impl<T> Deref for Box<T> { type Target = T; fn deref(&self) -> &T; }
impl<T> DerefMut for Box<T> { fn deref_mut(&mut self) -> &mut T; }

// Trait-object usage — the second major reason to reach for Box
type BoxedReader<'a> = Box<dyn sys.io::Reader + 'a>;
fn boxed_dyn_in<T: Trait + 'static>(value: T, a: &dyn Allocator) -> Result<Box<dyn Trait>, AllocError>;
```

## Key design decisions
- **Fallible construction (`Result`), consistent with every other `alloc` module** — a `Box::new` that could silently abort on OOM would be the one collection in the tier breaking the tier-wide "no hidden failure mode" contract; the ergonomic cost (an extra `?`/`.unwrap()` at every call site) is accepted here for the same reason it's accepted in `alloc.vec`.
- **`Box<dyn Trait>` is the officially sanctioned mechanism for dynamic dispatch across the whole `alloc` tier and above**, not an incidental capability — this matters because Principle 3 (small composable interfaces) only works in practice if there's one blessed way to type-erase a concrete implementation behind a trait/interface; without `Box<dyn Trait>` filling that role explicitly, individual modules would each invent their own erasure mechanism (function pointers, tagged unions, ad hoc vtables), which is exactly the kind of per-module reinvention Principle 4 exists to prevent.
- **No `Box::leak`/`Box::from_raw` exposed at this tier** — those exist in Rust's `Box` as an escape hatch into raw-pointer territory; here that capability is deliberately pushed to `core.ptr` (already an explicit, audited raw-pointer module) rather than duplicated on `Box`, keeping this module's surface limited to safe ownership transfer.
- **`Box<T>` is move-only with no `Clone` impl by default** — cloning requires `T: Clone` and an explicit `Box::new_in(box.deref().clone(), a)`-style call rather than an automatic derive, keeping heap-copy cost visible at the call site (this mirrors the report's general "no hidden allocation, ever" principle even where the operation, unlike growth, is nominally a single fixed-size copy).

## Validated by applications
- **archive-cli**: the compression/decompression backend is chosen at runtime (deflate vs. zstd vs. store) behind `std.compress`'s `Codec` interface; `archive-cli`'s own plumbing holds that choice as `Box<dyn Codec>` so the archive reader/writer doesn't need a generic type parameter threaded through every call in the tool's command dispatch — this validated that `Box<dyn Trait>`'s ergonomics (particularly that it composes with `sys.io`-style reader/writer traits with no special-casing) hold up in a real streaming-I/O context, not just a toy trait example.
- **doc-convert-tester**: the harness iterates "all known codecs" generically (per its own app profile's stress point on `core.convert`), which in practice means holding a `Vec<Box<dyn Codec>>` — a heterogeneous collection of concrete codec implementations behind one interface. This is the case that confirmed `Box` needs to compose cleanly with `alloc.vec` (a vec of boxes is an extremely common pattern) with no friction beyond ordinary generic-type usage.
- **chat-server**: per-connection handler state that's too large to want on a thread's stack (buffered partial-line input, per-client metadata) is heap-allocated via a plain `Box<ConnectionState>` per accepted connection — straightforward, unremarkable usage that's a useful negative-finding validation: `Box`'s common case (put one non-trait value on the heap) needed nothing beyond `Box::new`, confirming the minimal API doesn't need to grow for the most frequent real-world use.

## Open questions / risks
- Whether `Box<T>` should offer a `try_new`-vs-`new` naming split (matching some ecosystems' convention of reserving the plain name for an infallible/abort-on-failure variant, offered only at `std`) is an open naming-consistency question shared with `alloc.vec`'s `push` — resolved the same way here (fallible by default at this tier) for consistency, but flagged since it's the same tradeoff repeated across modules rather than one localized to `Box`.
