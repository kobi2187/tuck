# core.slice

## Purpose
A bounds-checked, non-owning view over a contiguous run of memory (`&[T]` / `&mut [T]`), plus the operations (indexing, splitting, sorting-by-comparator, searching) that work on that view regardless of what owns the backing storage — a stack array, a heap `Vec`, a memory-mapped file, or a hardware register block.

## Design lineage
Modeled jointly on Rust slices (bounds-checked, ownership-agnostic, with `split_at`/`chunks`/`windows` as the composable vocabulary) and Go slices (a view type decoupled from the backing array, cheap to pass by value as `(ptr, len)`), with Zig slices' insistence that length always travels with the pointer — no naked pointer-plus-separate-length convention anywhere in the stdlib, which the report's Part II flags as a chronic C/C++ defect (buffer overreads from a stale or miscomputed length).

## Proposed API
```
struct Slice<'a, T> { /* opaque: (ptr, len) pair with borrow-checked lifetime 'a */ }

impl<'a, T> Slice<'a, T> {
    fn len(&self) -> usize;
    fn is_empty(&self) -> bool;
    fn get(&self, i: usize) -> Option<&T>;              // bounds-checked, no panic
    fn index(&self, i: usize) -> &T;                     // panics/traps on OOB
    fn first(&self) -> Option<&T>;
    fn last(&self) -> Option<&T>;
    fn split_at(&self, mid: usize) -> (Slice<T>, Slice<T>);
    fn split_first(&self) -> Option<(&T, Slice<T>)>;
    fn chunks(&self, size: usize) -> impl Iterator<Item = Slice<T>>;
    fn windows(&self, size: usize) -> impl Iterator<Item = Slice<T>>;
    fn iter(&self) -> impl Iterator<Item = &T>;
    fn contains(&self, x: &T) -> bool where T: cmp::Eq;
    fn binary_search(&self, x: &T) -> Result<usize, usize> where T: cmp::Ord;
    fn sort_by(&mut self, cmp: impl FnMut(&T, &T) -> cmp::Ordering);
    fn copy_from_slice(&mut self, src: Slice<T>) where T: Copy;
    fn as_bytes(&self) -> Slice<u8> where T: Sized;      // reinterpret, explicit only
}

fn from_raw_parts<'a, T>(ptr: ptr::Ptr<T>, len: usize) -> Slice<'a, T>; // unsafe, in core.ptr terms
```

## Key design decisions
- `get()` (checked, returns `Option`) and `index()` (checked, traps) are both provided rather than one — the report's Principle 3 favors small composable pieces, but a single API forcing every hot-path lookup through `Option`-unwrapping was rejected after early drafting because `log-grep`-style byte scanning needs a zero-branch-overhead trapping form while parser code wants the `Option` form; both compile to the same bounds check, so the choice is purely about call-site ergonomics, not safety.
- `as_bytes()` is the *only* reinterpretation path and is explicit and named, rather than allowing implicit `T` → `[u8]` coercion anywhere else in the module — this keeps "treat structured memory as raw bytes" auditable, consistent with Principle 4's one-idiom-per-concern rule extended to type punning.
- Slices never allocate and never resize; `alloc.vec`'s growable array is defined as "a `Slice` plus capacity plus an allocator," not the other way around, keeping the dependency arrow pointing from `alloc` down to `core` as Principle 1 requires.

## Validated by applications
- **log-grep**: this app's stress point is explicit — whether `core.iter`'s adapters can run directly over a `sys.mmap`-backed region "with zero copies down to `std.regex`." That requirement forced `Slice` to support constructing a byte slice directly from a raw mapped-memory pointer (`from_raw_parts`) and to guarantee `chunks`/`windows`/`iter` compile to pure pointer arithmetic with no intermediate copy — a naive first design that only exposed slicing over owned `alloc.vec` buffers would have forced a memcpy at the mmap boundary, defeating the app's whole performance premise.
- **embedded-sensor-node**: listed as a directly exercised module because the ring buffer of samples, filter window, and I2C read buffer are all fixed memory with no heap. This confirmed `Slice` must be fully usable with `T: Copy`, no-allocator types (it already was, by construction — Principle 2 applies), and that `windows()` needed to be cheap and allocation-free enough to implement the moving-average filter directly, rather than requiring a separate "ring buffer view" type.
- **mp3-player**: `core.simd`'s volume-scaling/format-conversion operations need a mutable slice over an audio sample buffer as their operand; this is the primary indirect validation that `Slice` composes cleanly with `core.simd` rather than each defining its own buffer-view type — a real risk Principle 3 is meant to prevent.
- **diff-patch** (indirect, via `core.iter`'s validation): not listed in the app's own module table, but materially exercised once the edit-script is generated — grouping consecutive lines into unified-diff hunks with N lines of surrounding context needs exactly the lookahead/lookbehind `windows`/`chunks` already provide over the materialized `alloc.vec<EditOp>` slice. This is what let `core.iter` avoid needing its own windowing adapter (see that module's Validated section): by the time hunk assembly runs, the data is already a slice, so the existing `Slice::windows`/`chunks` from `log-grep`'s validation covers it with no new API needed here either.

## Open questions / risks
Whether `Slice` should carry a compile-time-known element stride assumption (for `as_bytes` safety across padding) is unresolved and pushed to `core.mem`'s layout guarantees.
