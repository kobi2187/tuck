# core.sync.cell

## Purpose
Single-threaded interior mutability: `Cell<T>` (copy-in/copy-out mutation through a shared reference, for small `Copy` types) and `RefCell<T>` (runtime-checked mutable/shared borrow tracking, for larger or non-`Copy` types) — for the common case of "logically mutable state reachable through an otherwise-shared reference," without paying for a lock.

## Design lineage
Modeled directly on Rust's `core::cell` (`Cell`/`RefCell` as the two single-threaded interior-mutability primitives, distinguished by whether the contained type is cheaply copyable), chosen because it is the only mechanism in the survey that lets a memory-safe systems language express "shared reference, but still mutable" without either a lock (too heavy for single-threaded state) or unchecked raw-pointer aliasing (unsafe by construction). Neither is `Sync` — this module is explicitly *not* a concurrency primitive; `core.atomic` and `sys.sync` own the cross-thread case.

## Proposed API
```
struct Cell<T> { /* opaque, T: Copy assumed for the ergonomic path */ }

impl<T: Copy> Cell<T> {
    fn new(value: T) -> Self;
    fn get(&self) -> T;               // copies out
    fn set(&self, value: T);          // copies in, no borrow tracking needed
    fn replace(&self, value: T) -> T;
}

struct RefCell<T> { /* opaque: T plus a runtime borrow-state counter */ }

impl<T> RefCell<T> {
    fn new(value: T) -> Self;
    fn borrow(&self) -> Ref<T>;               // panics/traps if currently mutably borrowed
    fn borrow_mut(&self) -> RefMut<T>;        // panics/traps if any borrow is outstanding
    fn try_borrow(&self) -> Result<Ref<T>, BorrowError>;
    fn try_borrow_mut(&self) -> Result<RefMut<T>, BorrowError>;
}

struct Ref<'a, T> { /* opaque guard, derefs to &T, decrements borrow count on drop */ }
struct RefMut<'a, T> { /* opaque guard, derefs to &mut T, on drop */ }
```

## Key design decisions
- `Cell<T>` and `RefCell<T>` are two types, not one generic-over-strategy type, because the cost model is fundamentally different: `Cell` is zero-overhead (a plain memory write, no runtime check) while `RefCell` pays a small counter check on every borrow — collapsing them would force every `Cell`-shaped use case (a simple mutable counter or flag behind a shared reference) to pay `RefCell`'s tracking overhead for no benefit.
- `borrow`/`borrow_mut` panic/trap on violation rather than silently allowing aliased mutable access — this is the direct enforcement of memory safety in a runtime-checked (not compile-time-checked) form, matching the same "verified where provable, checked at runtime otherwise" philosophy `core.error`'s contracts use, applied here to aliasing instead of arbitrary preconditions.
- Neither type implements `Sync`; sending a `Cell`/`RefCell` across threads (or sharing it between threads without synchronization) is a compile-time-rejected operation, not a runtime race — this is what lets `core.atomic`/`sys.sync` remain the sole cross-thread mechanisms without `core.sync.cell` becoming an accidental, unsound backdoor around them.

## Validated by applications
`core.sync.cell` is a substrate module — no app in the set calls `Cell`/`RefCell` at the top of its own business logic — but it underlies specific single-threaded state-sharing patterns inside several apps' otherwise concurrent or event-driven designs:
- **cli-hangman**: the app profile explicitly calls out testing the pure game-state machine "in complete isolation from `std.cli`'s I/O." A naive design threading a `&mut GameState` through both the test harness and the interactive input loop works, but the moment the app wants a single shared `GameState` reachable from both a rendering closure and an input-handling closure in the same single-threaded loop (a pattern the app's `--practice` stats tracking exercises), `RefCell` is what avoids restructuring the whole call graph around exclusive borrows — confirming the module earns its place even in the smallest app in the set, not just in complex concurrent ones.
- **todo-cli**: the append-only undo log needs to be mutated from within iterator/closure contexts that also read the current task list (e.g., "for each matched task, mark done and append an undo entry") — modeling this with `Cell`/`RefCell` around the log rather than restructuring the filter-then-mutate logic into two disjoint passes was the pattern that kept the query-then-mutate code simple, which is exactly the kind of naive-first-design refinement this app's iterator-heavy filtering surfaced.
- **chat-server**: if built on a single-threaded event-loop model (one of the two concurrency styles the app profile explicitly says is a real comparison point against a thread-per-connection model), per-connection local state (partially-parsed input buffer, last-activity timestamp) is naturally `Cell`/`RefCell`-based rather than atomic, since it's only ever touched by the one event-loop thread — this is the clearest illustration of why `core.sync.cell` and `core.atomic` must remain two distinct mechanisms rather than one "just always synchronize" default.

## Open questions / risks
Whether `RefCell`'s violation response should be a recoverable `Result` (`try_borrow`) uniformly, rather than defaulting to panic/trap for the common `borrow`/`borrow_mut` path, is worth revisiting against `core.error`'s contract philosophy — currently mirrors Rust's precedent rather than being independently re-derived.
