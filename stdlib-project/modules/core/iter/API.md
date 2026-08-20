# core.iter

## Purpose
The single lazy-iteration abstraction — one `Iterator` interface plus a standard set of adapters (`map`, `filter`, `fold`, `zip`, `take`, `chain`, `enumerate`) — that every iterable thing in the stdlib (slices, strings, ranges, later hash maps) implements once and composes through freely.

## Design lineage
Modeled on Rust's `Iterator` trait (pull-based, adapter methods return new lazy iterators, terminal methods like `fold`/`collect` force evaluation) with D's ranges + UFCS cited in the report as the other strong influence for fluent, chainable pipeline syntax without requiring every adapter to be a method defined on the source type itself. Rust's model was chosen over D's because Rust's version composes with `core`'s no-allocator constraint without extra ceremony — D's lazier UFCS chaining still typically assumes a GC-backed runtime for some range combinators, which this tier cannot assume (Principle 2).

## Proposed API
```
trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;   // the only required method

    // Provided (default-implemented) adapters, all lazy:
    fn map<B>(self, f: impl FnMut(Self::Item) -> B) -> impl Iterator<Item = B>;
    fn filter(self, pred: impl FnMut(&Self::Item) -> bool) -> impl Iterator<Item = Self::Item>;
    fn zip<U: Iterator>(self, other: U) -> impl Iterator<Item = (Self::Item, U::Item)>;
    fn take(self, n: usize) -> impl Iterator<Item = Self::Item>;
    fn skip(self, n: usize) -> impl Iterator<Item = Self::Item>;
    fn chain(self, other: impl Iterator<Item = Self::Item>) -> impl Iterator<Item = Self::Item>;
    fn enumerate(self) -> impl Iterator<Item = (usize, Self::Item)>;
    fn peekable(self) -> Peekable<Self>;

    // Terminal (eager) consumers:
    fn fold<B>(self, init: B, f: impl FnMut(B, Self::Item) -> B) -> B;
    fn count(self) -> usize;
    fn find(self, pred: impl FnMut(&Self::Item) -> bool) -> Option<Self::Item>;
    fn any(self, pred: impl FnMut(Self::Item) -> bool) -> bool;
    fn for_each(self, f: impl FnMut(Self::Item));
}

trait IntoIterator {
    type Item;
    type IntoIter: Iterator<Item = Self::Item>;
    fn into_iter(self) -> Self::IntoIter;
}
```

## Key design decisions
- Only `next()` is required; every adapter is a default method built on top, so implementing `Iterator` for a new source (a hardware register stream, a custom ring buffer) is a one-method commitment — directly serving Principle 3's "small interfaces" over requiring a large vtable of overridable methods.
- Adapters are lazy and allocation-free by construction (each returns a new zero-size or small-state iterator wrapping the previous one, never a materialized collection) — this is what makes `core.iter` usable in `core` at all rather than requiring `alloc`; `collect()`-into-a-container is deliberately *not* defined here and lives in `alloc` where a growable target type can exist.
- `fold` is kept as the one universal terminal reducer (from which `sum`, `count`, `any` are all derivable) rather than defining a large family of independent terminal methods first — the provided convenience methods (`count`, `find`, `any`) exist for ergonomics but are specified as being expressible in terms of `fold`, keeping the "one coherent idiom" promise even for the terminal side of the trait.

## Validated by applications
- **log-grep**: the app profile explicitly frames this as the test of whether `core.iter` can run directly over an `sys.mmap`-backed byte region with zero copies down to `std.regex`. This confirmed the adapter chain (`bytes().enumerate()` style line-splitting) must compile away entirely under optimization to raw pointer walks — validated the "no hidden allocation" design but also showed that a line-splitting adapter needed to be added as a first-class provided method (`split_on`-style, working over any `Iterator<Item = u8>`) rather than forcing every mmap consumer to hand-roll it, since re-deriving it from `fold` alone in every app was exactly the kind of ceremony Principle 5 (radical minimalism below `std`, but still ergonomic) warns against.
- **cli-hangman**: iterating the letters of the secret word to check win/loss is the simplest possible `core.iter` use case, and the app's own stated purpose is to be a control case for ceremony — confirmed that `chars().all(...)`-style one-liners work with no setup, which is the bar the module is held to.
- **todo-cli**: filtering the task list by the query mini-language (`project:home +urgent due:today`) is naturally a `filter().filter().sorted_by(...)` chain; this surfaced that `core.iter` alone is insufficient for the sort step (sorting needs to collect first, which requires `alloc`), confirming the deliberate `core`/`alloc` split rather than trying to offer a lazy sort in `core`.
- **math-toolkit-cli**: `mtk stats data.csv --column price` is this module's first direct test of Design Principle 3's claim that `core.iter` composes with `std.math` rather than requiring a materialized slice. It splits cleanly into two cases that validate two different parts of the existing design: mean/variance (computable single-pass via Welford's algorithm) are a pure `fold` over the column iterator with no allocation at all, confirming the terminal-reducer design holds up for real streaming statistics, not just toy examples; percentiles (p50/p90/p99), which need sorted order, cannot be done lazily and require collecting into an `alloc.vec` first — the same `core`/`alloc` split `todo-cli`'s sort requirement already established, now reconfirmed for a numeric rather than a struct workload. No change to `core.iter` was needed for either case.
- **diff-patch**: the app profile's own stated stress point is whether `core.iter`'s adapters (windows, chunking, zip) are expressive enough to implement Myers diff/LCS "without dropping to manual index arithmetic." This resolves as a qualified yes, and the qualification is the actual finding: the LCS/Myers dynamic-programming table itself is **not an iterator-shaped problem at all** — filling cell `(i, j)` requires random-access reads of the cells above, to the left, and diagonally above-left, which is 2D indexing driven by a recurrence relation, not a linear pull-based `next()` sequence. No amount of adapter-chaining turns a 2D recurrence into a fold over a 1D stream, and trying to force it into `core.iter`'s shape would just relocate the "manual index arithmetic" the app was trying to avoid into more convoluted adapter code instead of removing it. That's not a gap in `core.iter` — it's a second, sharper confirmation of the same `core`/`alloc` split `todo-cli`'s sort and `math-toolkit-cli`'s percentiles already established: the DP table is `alloc`-tier indexed storage (see `alloc.vec`'s new `Grid<T>`, added directly in response to this app), and `core.iter` correctly stays out of that part. Where `core.iter` *is* the right tool — scanning line-equality while feeding the table's inputs, and walking the backtrace into a flat edit-script — plain `zip`/`enumerate`/`fold` sufficed with no new adapter needed. The one place `windows`/`chunks` genuinely get used (grouping the flat edit-script into unified-diff hunks with N lines of context around each change) turned out to already be served by `core.slice::windows`/`chunks` (present since `log-grep`'s validation), once the edit-script is materialized into a slice — which it must be regardless, since context/hunk-boundary lookahead isn't expressible over a single lazy pass without buffering anyway. **No new adapter was added to `core.iter`**; `core.slice`'s existing `windows`/`chunks` plus the established `core`/`alloc` split for the DP table cover this app's needs in full.

- **sudoku-solver**: "iterate all 27 constraint groups (9 rows, 9 columns, 9 boxes) as a unified abstraction" turns out, on inspection, to be a close cousin of `diff-patch`'s DP-table finding rather than a new kind of problem: a 3x3 box is not slice-shaped (its 9 cells are neither contiguous nor a fixed stride apart in a row-major `Array<Array<Cell, 9>, 9>`), so no chain of `map`/`filter`/`zip`/`enumerate` over the grid's existing row/column iteration produces it — the coordinate math (`box b` covers rows `(b/3)*3..+3`, cols `(b%3)*3..+3`) is fundamentally index arithmetic, not a pull-based sequence transformation, the same way Myers-diff's DP recurrence was. The resolution is the same shape `diff-patch` already established for its DP table: materialize the index structure once, then let ordinary iteration do the rest. Concretely, a `const`-computed `Array<Array<(usize, usize), 9>, 27>` (rows 0-8, columns 9-17, boxes 18-26 — built once via `core.array::from_fn`, see that module's validated-by entry) holds each group's 9 `(row, col)` coordinates; every one of the app's actual per-group operations (checking for a naked single, finding a hidden single, applying pointing-pair elimination) is then a completely ordinary `.iter().map(...)`/`.fold(...)`/`.any(...)` over one group's 9 coordinates, with zero grid-specific knowledge inside `core.iter` itself. **No new adapter was added** — this reconfirms, on a second and structurally different app, the same finding `diff-patch` produced: `core.iter` correctly stays generic over "a sequence of items," and 2D/grouped-index structure that isn't naturally sequential belongs in a precomputed index table built with `core.array`/`core.iter` together, not in a bespoke grid-aware iterator adapter.

## Open questions / risks
Whether `Iterator` should require a `size_hint()` method (useful for `alloc.vec::collect` to pre-size) is unresolved — adding it later without breaking the one-method-minimum promise needs a default that degrades gracefully.
`math-toolkit-cli`'s CSV column may contain malformed numeric cells; parsing each row into a `Result<f64, ParseError>` and then wanting to short-circuit the whole `fold` on the first error is achievable today only by hand-rolling a loop against the required `next()` method, since no `try_fold`/`try_for_each` adapter is specified. Whether that's an acceptable amount of ceremony for a genuinely common "parse-then-reduce untrusted input" pattern, or whether it warrants a first-class fallible-fold adapter, is unresolved — flagged rather than added speculatively, per Principle 5.
