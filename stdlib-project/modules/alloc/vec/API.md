# alloc.vec

## Purpose
A growable, contiguous, heap-allocated array — the default general-purpose collection above `core.slice`, and the type most other `alloc`-tier modules (`string`, `deque`, `map`'s bucket storage) are built on top of internally.

## Design lineage
Modeled on **Rust's `Vec<T>`** (owning, amortized-doubling growth, deref-to-slice so it composes directly with `core.slice`) and **C++'s `std::vector`** (the reserve/capacity split). Go's `append` semantics inform the growth-factor guidance (favor throughput over tight memory) but Go's implicit, unconfigurable allocator is explicitly rejected here per Principle 2 — every constructor takes or defaults an `alloc.allocator::Allocator`.

## Proposed API
```
struct Vec<T> { .. }

impl<T> Vec<T> {
    fn new() -> Self;                                  // uses alloc.allocator::default_allocator()
    fn new_in(a: &dyn Allocator) -> Self;               // explicit allocator, first-class not bolted-on
    fn with_capacity(n: usize) -> Self;
    fn with_capacity_in(n: usize, a: &dyn Allocator) -> Self;

    fn push(&mut self, value: T) -> Result<(), AllocError>;   // fallible: no hidden abort-on-OOM below std
    fn pop(&mut self) -> Option<T>;
    fn insert(&mut self, index: usize, value: T) -> Result<(), AllocError>;
    fn remove(&mut self, index: usize) -> T;
    fn swap_remove(&mut self, index: usize) -> T;

    fn reserve(&mut self, additional: usize) -> Result<(), AllocError>;
    fn shrink_to_fit(&mut self) -> Result<(), AllocError>;
    fn truncate(&mut self, len: usize);
    fn clear(&mut self);

    fn as_slice(&self) -> &[T];                         // core.slice interop
    fn as_mut_slice(&mut self) -> &mut [T];
    fn len(&self) -> usize;
    fn capacity(&self) -> usize;
    fn allocator(&self) -> &dyn Allocator;

    fn extend_from_slice(&mut self, s: &[T]) -> Result<(), AllocError> where T: Clone;
    fn retain(&mut self, f: impl FnMut(&T) -> bool);
    fn iter(&self) -> core.iter::Iter<T>;                // feeds core.iter's lazy adapters directly
}

// Added for diff-patch — see Key design decisions "Revision (diff-patch)".
// A fixed-shape 2D table backed by one contiguous Vec<T> (row-major stride
// indexing), for dynamic-programming tables and similar fixed-shape 2D data.
// Not a matrix-math type: no arithmetic operators, no resizing after
// construction, deliberately narrow.
struct Grid<T> { .. }

impl<T: Clone> Grid<T> {
    fn new_in(rows: usize, cols: usize, fill: T, a: &dyn Allocator) -> Result<Self, AllocError>;
    fn get(&self, row: usize, col: usize) -> &T;
    fn get_mut(&mut self, row: usize, col: usize) -> &mut T;
    fn row(&self, row: usize) -> &[T];                   // one row as a contiguous slice, no copy
    fn row_mut(&mut self, row: usize) -> &mut [T];
    fn rows(&self) -> usize;
    fn cols(&self) -> usize;
    fn as_flat_slice(&self) -> &[T];                      // escape hatch: the whole backing buffer
}
```

## Key design decisions
- **`push`/`insert`/`reserve` return `Result`, not panic-on-OOM.** This is the sharpest departure from Rust's `Vec` (which aborts) and is deliberate: `alloc` is usable on embedded targets where OOM is a routine, recoverable event, not a process-ending bug. A `Vec::push_unwrap` extension is *not* provided in `alloc` — that convenience belongs at `std`, where aborting is a defensible default, keeping the floor tier honest about failure.
- **Default-allocator ergonomics via two-constructor pattern.** `Vec::new()` (implicit default allocator) sits alongside `Vec::new_in(&a)` (explicit) rather than an optional/nullable allocator parameter, so the explicit path is exactly as fast (no branch, no `Option` unwrap) as the convenience path — a language-level default-argument or overload resolves to the same generated code either way. This is the pattern every other `alloc` module below follows for consistency (Principle 4 applied to allocator ergonomics itself).
- **Growth factor is a strategy hook, not hardcoded.** `Vec` exposes the amortized-doubling default but an internal `GrowthPolicy` trait (not shown above for brevity) lets `with_capacity_in` callers on memory-constrained targets specify linear or 1.5x growth to reduce peak fragmentation against a `PoolAllocator` — a direct response to mp3-player's playlist `Vec` sharing an arena with other allocations where doubling growth could otherwise waste an arena's worth of space on a single resize.
- **No `Vec::from_iter` that hides allocator choice.** Any constructor that allocates takes or defaults an allocator explicitly; there is deliberately no blanket `impl FromIterator for Vec<T>` of the Rust kind, since that pattern is exactly where "hidden allocation" silently reappears in ergonomic Rust code. Instead: `Vec::from_iter_in(iter, &a)`.
- **Revision (diff-patch): added `Grid<T>`, a flat-`Vec`-backed 2D table.** The LCS/Myers DP table is exactly the case the original design didn't name: plain `Vec<T>` forces every call site to hand-compute `row * cols + col` — precisely the "manual index arithmetic" `diff-patch`'s app profile calls out as the thing worth avoiding — and `Vec<Vec<T>>` pays one heap allocation per row (for an `(n+1) x (m+1)` LCS table over a large file diff, that's thousands of independently-fallible allocations, plus non-contiguous memory on an already-O(n·m) hot inner loop). `Grid<T>` is a thin wrapper over a single `Vec<T>` (row-major stride) that gives 2D-indexing ergonomics (`get(row, col)`, `row(i)` returning a contiguous slice usable directly with `core.iter`/`core.slice`) without hiding that it's still one flat allocation underneath — `as_flat_slice()` keeps the whole-buffer escape hatch visible, consistent with this module's "no hidden cost" posture. It is deliberately *not* a general matrix type (no arithmetic ops, fixed shape once constructed) — scoped narrowly to "fixed-shape 2D table, indexed not computed over," which is the actual need this app has; a real matrix/linear-algebra type belongs at `std.math` if one is ever needed.

## Validated by applications
- **web-downloader**: buffers each chunk of a streamed HTTP response into a `Vec<u8>` before handing it to `sys.fs`; needs `reserve`+`extend_from_slice` to avoid a `push`-per-byte hot loop, and needs `push`'s `Result` return to compose cleanly with the app's existing retry/backoff error path rather than requiring a separate panic-catching layer.
- **archive-cli**: streaming compression backends fill a `Vec<u8>` scratch buffer per chunk; this is the app that forced `shrink_to_fit` to exist as a real method rather than an afterthought, since a long archive run must not let scratch buffers sized for one large file linger at that capacity through thousands of subsequent small files.
- **mp3-player**: the playlist itself is a small `Vec<Track>` built once at load time via `Vec::new_in(&general_purpose)`, off the audio hot path — validating that the *default* is fine for UI-thread data even in an app whose headline requirement is avoiding the default allocator elsewhere. This is a useful negative case: not every `Vec` in a real-time app needs a special allocator, only the ones actually on the callback path.
- **todo-cli**: the append-only undo log is a `Vec<ChangeRecord>` that only ever grows (`push`) and is walked backward for undo — this is the case that validated `push` needing to be genuinely cheap in the common (non-resizing) path, since every task mutation appends one record.
- **diff-patch**: the direct forcing function for `Grid<T>` (see Key design decisions). The LCS dynamic-programming table needs indexed random access to three neighboring cells per entry (`grid[i-1][j]`, `grid[i][j-1]`, `grid[i-1][j-1]`) while being filled row by row — `Grid<T>` resolves it with one allocation, `.get(i, j)`/`.get_mut(i, j)` at call sites, and `.row(i)` for the backtrace walk. The unified-diff hunk-assembly step, by contrast, only ever needs the flat 1D edit-script (`Vec<EditOp>`) — confirming `Grid<T>` is genuinely a 2D-table-specific need and not a general replacement for `Vec` wherever a nested `Vec<Vec<T>>` might otherwise have been reached for out of habit.

- **sudoku-solver**: two distinct needs, both already served without change. The backtracking search's undo log/move stack is a plain `Vec<Move>` (`push` on each trial assignment, `pop` on backtrack) — an ordinary, unremarkable `Vec` use, not a new case. The 9x9 board itself is explicitly *not* a `Grid<T>` candidate: its size is a compile-time constant (9x9, always), so it belongs to `core.array`'s nested `Array<Array<Cell, 9>, 9>` instead (see that module's validated-by entry, which resolves the fixed-size-vs-dynamic question directly rather than adding a `Grid<T>`-adjacent fixed-size variant here) — confirming `Grid<T>` is correctly scoped to *dynamically*-sized 2D data and that a fixed-size sibling type is unnecessary rather than a gap in this module.
- **backup-sync**: confirmed as a negative case, explicitly. Nothing in this app's feature set (tree walking, size/mtime comparison, whole-file copy, rolling-checksum block diffing) is 2D-indexed data — the delta-diffing block table is a flat sequence of `(offset, checksum)` records scanned and compared linearly, not a table addressed by two independent coordinates the way an LCS DP table or a game board is. `Grid<T>` is not exercised by this app at all; ordinary `Vec<T>` (for the block-checksum list) and `push`/`iter` cover its `alloc.vec` needs in full.

## Open questions / risks
- Fallible `push` pushes error-handling ceremony into every call site; whether that's the right tradeoff for `std`-tier code (which typically *does* want abort-on-OOM ergonomics) is deferred to `std.collections`-style wrappers, not resolved here — flagged so it isn't silently forgotten.
