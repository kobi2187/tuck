# alloc.list

## Purpose
A classic (non-intrusive) doubly-linked list, provided for the narrow cases where `alloc.vec`/`alloc.deque` genuinely don't fit — O(1) splice/merge of large sequences, or stable element addresses across insertion/removal anywhere in the sequence — and documented as deliberately a last resort.

## Design lineage
Modeled on **Rust's `LinkedList<T>`**, chosen specifically *because* Rust's own standard library documentation for that type is unusually candid that it is "almost never" the right choice and recommends `Vec`/`VecDeque` for nearly every workload people reach for a linked list for. This module inherits that stance verbatim rather than pretending the type is a neutral general-purpose tool: the report's survey found no mature language stdlib whose linked list beats an array-based structure on the benchmarks people actually care about (sequential access, cache behavior, memory overhead), so the API here is deliberately kept minimal and the documentation deliberately steers callers away, per Principle 3's push toward the smallest interface that solves the actual problem.

## Proposed API
```
struct List<T> { .. }   // doubly-linked, one heap allocation per node

impl<T> List<T> {
    fn new() -> Self;
    fn new_in(a: &dyn Allocator) -> Self;

    fn push_front(&mut self, v: T) -> Result<(), AllocError>;
    fn push_back(&mut self, v: T) -> Result<(), AllocError>;
    fn pop_front(&mut self) -> Option<T>;
    fn pop_back(&mut self) -> Option<T>;

    fn cursor_front_mut(&mut self) -> CursorMut<T>;    // the actual reason to reach for this module:
    fn cursor_back_mut(&mut self) -> CursorMut<T>;     // O(1) insert/remove/splice at a known position

    fn append(&mut self, other: &mut List<T>);          // O(1) splice of two whole lists — the headline capability
    fn len(&self) -> usize;
    fn iter(&self) -> core.iter::Iter<&T>;
    fn allocator(&self) -> &dyn Allocator;
}

impl<'a, T> CursorMut<'a, T> {
    fn current(&mut self) -> Option<&mut T>;
    fn insert_before(&mut self, v: T) -> Result<(), AllocError>;
    fn insert_after(&mut self, v: T) -> Result<(), AllocError>;
    fn remove_current(&mut self) -> Option<T>;
    fn move_next(&mut self);
    fn move_prev(&mut self);
}
```

## Key design decisions
- **No `get(index)` random-access method.** Deliberately absent — a linked list's O(n) indexed access is the single most common performance footgun of reaching for this type instead of `Vec`, so the API doesn't offer an easy way to write an accidentally-quadratic loop; the only supported access patterns are sequential iteration and cursor-based, position-relative operations.
- **`append` (O(1) whole-list splice) and cursor-based `insert_before`/`insert_after`/`remove_current` are the entire value proposition kept in the API surface** — everything else a linked list "can do," `Vec`/`Deque` do as well or better, so this module doesn't try to be a general-purpose sequence type with a different Big-O profile; it's scoped to exactly the two operations where the node-based structure genuinely wins.
- **The module doc itself, not just a code comment, states the "probably don't use this" guidance up front** (mirroring Rust's own `LinkedList` docs) — this is a conscious choice about where guidance belongs: a design principle from Part III ("small, composable interfaces") is being applied here to *steer choice*, not just to shrink an API, since the failure mode this module guards against is social/habitual (reaching for "linked list" out of habit from a data-structures course) rather than a missing method.

## Validated by applications
- **No surveyed app needs this module**, and that absence is itself the validation the report's methodology asked for. `chat-server`'s room membership list was an early candidate (`List<ClientHandle>` for join/leave order) but on inspection, `alloc.map`'s `room -> Vec<ClientHandle>` already handles broadcast iteration and removal-by-id better (removal by id is O(n) either way for an unordered room, but `Vec` has far better cache behavior for the broadcast-to-all-members hot path, which dominates); this is the instructive precedent the report's design brief specifically asked this module's doc to capture.
- **mp3-player**'s playlist and **todo-cli**'s undo log were both also initially plausible `List` candidates (sequences with mid-sequence insertion) but both resolved to `Vec`/`Deque` once actually specified: the playlist rarely splices, and the undo log is strictly append-only — neither needed O(1) arbitrary-position splice, only sequential access, which `Vec` gives with better cache locality and lower per-element overhead (no two-pointer node header per element).
- If a future app profile needs true O(1) merge of two large, already-built sequences at an unpredictable point (e.g., an external-merge-sort intermediate step), that would be the concrete case that finally exercises `append`; none of the eleven surveyed apps does this, which is a real (not hypothetical) finding about how rarely this module's headline capability is actually needed in practice.

## Open questions / risks
- Given zero apps in the validation set need this module at all, it's worth asking whether `alloc.list` should ship in the default `alloc` tier or move to an opt-in "collections extras" corner even within `alloc` — kept in-tier here only because Tier 1's table (REPORT.md, Part IV) explicitly lists it, but this doc's own findings are a reasonable basis for revisiting that inclusion.
