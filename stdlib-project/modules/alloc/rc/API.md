# alloc.rc

## Purpose
Reference-counted shared heap ownership, with a companion non-owning `Weak` handle to break reference cycles — for the (deliberately less common than `Box`) cases where a value genuinely needs multiple owners with no single point that can be identified as "the" owner.

## Design lineage
Modeled on **Rust's `Rc<T>`/`Weak<T>`** (single-threaded, non-atomic refcount, separate `Arc<T>` implied for cross-thread sharing at the `sys` tier where atomics have OS-level meaning) and **C++'s `shared_ptr`/`weak_ptr`** for the strong/weak split that prevents the classic cycle-induced leak. The report's survey (Part II) treats "shared ownership as a last resort, not a default" as a lesson worth taking specifically from Rust's culture around this type — languages with pervasive GC (Java, Go, JS) never had to name this cost explicitly, and the design here keeps that cost visible rather than ambient.

## Proposed API
```
struct Rc<T> { .. }        // single-threaded strong reference, non-atomic refcount
struct Weak<T> { .. }      // non-owning; does not keep the value alive

impl<T> Rc<T> {
    fn new(value: T) -> Result<Self, AllocError>;                 // default allocator
    fn new_in(value: T, a: &dyn Allocator) -> Result<Self, AllocError>;
    fn clone(&self) -> Self;                                      // increments strong count, no allocation
    fn downgrade(&self) -> Weak<T>;                                // increments weak count
    fn strong_count(&self) -> usize;
    fn weak_count(&self) -> usize;
    fn get_mut(&mut self) -> Option<&mut T>;                       // Some only if strong_count == 1
    fn ptr_eq(a: &Self, b: &Self) -> bool;                         // identity, not value, comparison
}

impl<T> Weak<T> {
    fn upgrade(&self) -> Option<Rc<T>>;                            // None if the value was already dropped
}

impl<T> Deref for Rc<T> { type Target = T; fn deref(&self) -> &T; }
```

## Key design decisions
- **`Rc` is explicitly single-threaded (non-atomic); there is no `Arc` in the `alloc` tier.** Atomic reference counting only has coherent semantics once there's a real concept of concurrent threads sharing memory, which `alloc` (no-OS) doesn't guarantee exists — a thread-safe `Arc<T>` belongs at `sys` (alongside `sys.thread`/`sys.sync`), built on `core.atomic`, not duplicated here with a runtime "is this thread-safe" flag. This is a direct application of Principle 1 (layer by dependency, not topic): "shared ownership" as a concept is `alloc`-tier, but "shared ownership safe across OS threads" is `sys`-tier by definition, so the module boundary is drawn there rather than papered over with a generic parameter.
- **`get_mut` returning `Option` (not a panicking "must be unique" method) is the only mutation path**, forcing callers to handle the shared case explicitly rather than reaching for interior mutability by default — where genuine shared mutability is needed, the caller is expected to combine `Rc<T>` with `core.sync.cell`'s `RefCell`-equivalent explicitly (`Rc<RefCell<T>>`, the well-known and intentionally visible Rust idiom) rather than `Rc` growing its own hidden interior-mutability escape hatch.
- **No automatic cycle detection.** `Weak` is the entire answer to reference cycles at this tier — consistent with every mature survey entry (Rust, C++, Swift's ARC) landing on "manual weak references, no tracing collector" for non-GC languages, and consistent with `alloc` explicitly being the no-OS, no-runtime-services tier where a background cycle collector couldn't live anyway.
- **`Rc::clone` is a cheap, non-fallible refcount bump**, distinguished sharply in the API from `Rc::new`/`new_in` (fallible, allocating) — this asymmetry is intentional and documented so callers don't reflexively wrap every `.clone()` call in error handling meant for the initial allocation.

## Validated by applications
- **chat-server**: a client's connection handle is naturally shared — held once by the accept loop, once by each room the client has joined, and once by the per-connection reader task. `Rc<ClientHandle>` (promoted to `sys.thread`-safe `Arc` once threads enter the picture, per the design decision above) is the direct fit; this app is what confirmed `Weak` is needed too — a room's member list holding `Weak<ClientHandle>` instead of `Rc` avoids keeping a disconnected client's state alive purely because a room forgot to clean up its membership list on disconnect, which is a real bug class this module is designed to make structurally harder to write.
- **podcast-subscriber**: show metadata (title, feed URL, artwork path) is looked up once per feed poll but referenced by every episode belonging to that show in the local library index; representing each episode's `show` field as `Rc<ShowMetadata>` instead of duplicating the metadata per episode was the concrete case that validated `Rc`'s value as a memory/consistency optimization (one update to a show's title reflects everywhere) rather than purely an ownership-modeling convenience.
- **mp3-player**: initially, a naive design put the decoded ID3 tag data behind `Rc<TrackMetadata>` shared between the playlist entry and the "now playing" UI display state; on closer inspection this was downgraded to plain ownership (`TrackMetadata` cloned or referenced by index into the playlist `Vec`, per `alloc.vec`) because the sharing wasn't actually multi-owner — only one thing displays "now playing" at a time. This is a useful negative finding: `Rc` was the first instinct but not the right call here, reinforcing the module doc's stance that shared ownership should be reached for only when multiple *independent* owners genuinely exist.

## Open questions / risks
- The `Rc`-vs-`Arc` split pushes a real decision onto every app: "do I need thread-safety yet?" — for an app like chat-server that starts single-threaded conceptually but adds concurrency once real sockets are involved, switching `Rc<T>` to `Arc<T>` is a type-level change, not a flag flip; whether the two types should share enough surface API to make that migration mechanical (same method names, same `Deref` behavior) is asserted here as a goal but needs to be validated against `sys.sync`'s actual `Arc` design once that module is drafted.
