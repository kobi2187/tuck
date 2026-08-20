# core.array

## Purpose
A fixed-size, value-typed, stack-allocatable collection `[T; N]` whose length is part of its type — distinct from `core.slice`'s runtime-length view — used wherever a size is known at compile time: hardware register layouts, cryptographic key/nonce sizes, small inline buffers.

## Design lineage
Modeled on Rust's `[T; N]` (const-generic length baked into the type, so a function taking `[u8; 32]` statically rejects a 16-byte key) and Zig's arrays (value semantics, `@sizeOf` known at compile time, freely embeddable in structs without indirection). The report's survey notes this distinction is frequently collapsed in weaker designs (C's array-decays-to-pointer erasing length information entirely) — keeping `array` and `slice` as two types, with an implicit borrow from the former to the latter, is a direct fix.

## Proposed API
```
type Array<T, const N: usize> = [T; N];

impl<T, const N: usize> Array<T, N> {
    fn len(&self) -> usize;                 // always == N, resolvable at compile time
    fn as_slice(&self) -> slice::Slice<T>;   // implicit-by-convention borrow, zero cost
    fn as_mut_slice(&mut self) -> slice::Slice<T>;
    fn map<U>(self, f: impl FnMut(T) -> U) -> Array<U, N>;
    fn from_fn(f: impl FnMut(usize) -> T) -> Array<T, N>;
    fn zip<U>(self, other: Array<U, N>) -> Array<(T, U), N>;
}

// N-preserving construction avoids the "array literal has wrong length" class
// of error being caught only at use, not at the literal itself:
fn splat<T: Copy, const N: usize>(value: T) -> Array<T, N>;
```

## Key design decisions
- `Array<T, N>` implicitly borrows to `Slice<T>` (via `as_slice`, and via an automatic reference coercion at call sites expecting a slice parameter) so that the overwhelming majority of `core.slice`'s operations — search, sort, chunk — never need array-specific duplicates; only truly size-dependent operations (`map`, `zip`, `from_fn`) live on `Array` itself.
- `len()` returning a value that is also known at compile time (`N`) is kept as a runtime-callable method, not only a type-level constant, so generic code written against `core.slice`-shaped duck typing doesn't need a special case for arrays.
- No implicit resizing or "array of arrays flattens to slice" magic — Principle 2 (no hidden anything below `std`) extends here to "no hidden reshaping," keeping memory layout exactly as declared.

## Key design decisions (continued)
- **Revision (sudoku-solver): no `Grid2D<T, const R: usize, const C: usize>` type added — nested `Array<Array<T, C>, R>` already covers the fixed-size 2D case, and adding a dedicated type would be solving a problem that doesn't exist at this tier.** `alloc.vec::Grid<T>` (added for `diff-patch`) exists because a heap `Vec<T>` is *flat*: without a wrapper, every 2D access needs caller-computed `row * cols + col` stride arithmetic, and the naive alternative (`Vec<Vec<T>>`) pays one independently-fallible heap allocation per row. Neither problem exists for a compile-time-sized grid: `Array<Array<Cell, 9>, 9>` is already a value type with `grid[r][c]` indexing built directly into the language/type system — no stride math, no per-row allocation (there's no allocation at all), and `grid[r]` already yields a real `Array<Cell, 9>` (itself sliceable via `as_slice()`) with zero ceremony. A `Grid2D` wrapper over the same nested array would add a type without removing any work the caller was doing — the actual over-engineering the app profile asked this module to check for. The one place the two designs are *not* symmetric, and worth naming explicitly: `alloc.vec::Grid<T>::row(i)` returns a genuinely contiguous slice (flat backing store, row-major), while a nested `Array<Array<T, C>, R>`'s "column" is not contiguous (each element is one stride of `C` apart) — accessing a whole column cheaply is not free the way a whole row is, on *either* side of this comparison; that asymmetry is inherent to row-major layout, not an artifact of which module owns the type, so it isn't a reason to add a new type here either.
- **Indexing-convention consistency, resolved without a shared type.** Even without a shared `Grid`/`Grid2D` type spanning both tiers, this module adopts the same `(row, col)` ordering `alloc.vec::Grid<T>::get(row, col)` already established, for any code (like sudoku-solver's constraint-group index table — see `core.iter`'s validated-by entry) that builds `(usize, usize)` coordinate pairs over a fixed `Array`-backed grid. A reader moving between a heap-backed `Grid<T>` and a stack-backed nested `Array` sees one coordinate convention, not two competing ones, which is the actual coherence the app profile asked this module to check for — achieved by convention rather than by forcing a shared type across the freestanding/heap boundary where the underlying memory-layout tradeoffs (see above) are genuinely different.

## Validated by applications
- **sudoku-solver**: the 9x9 board is `Array<Array<Cell, 9>, 9>` — the first app in this project to seriously exercise a fixed-size compile-time 2D grid, and the direct forcing function for the `Grid2D` question above. `from_fn` (already in the API) turns out to be exactly the right tool for the app's other fixed-size-2D need too: precomputing the "27 constraint groups" index table (see `core.iter`) is a nested `from_fn` — an outer `Array<_, 27>::from_fn(|g| ...)` building each group's `Array<(usize, usize), 9>` — with no new `core.array` method required.
- **secrets-vault**: AEAD keys, nonces, and salts are fixed-length by cryptographic construction (a 32-byte key is never a 31- or 33-byte key), and the app's "fail closed" requirement is best served by the *type* rejecting a wrong-length buffer at the call boundary rather than a runtime length check inside `std.crypto`. This is the strongest real-world case for `Array<u8, N>` over `Slice<u8>` as a function parameter type in the whole survey, and it directly validates keeping `array` a distinct, const-generic type rather than folding it into `slice` for simplicity as an early draft considered.
- **embedded-sensor-node**: I2C register maps and the fixed-capacity flash ring buffer are naturally `Array`, not `Slice`, because their size is a hardware/memory-layout constant known at compile time, not a runtime property; `from_fn` was added specifically to let firmware initialize a register-read buffer without a heap or a loop-with-bounds-check the compiler can't fully elide.
- **mp3-player**: ID3v2 frame headers are fixed-width binary structures decoded via `std.encoding`'s binary struct packing; `Array<u8, N>` gives that decoder a type-safe fixed-size scratch buffer per frame field (e.g. a 4-byte frame-ID) without falling back to `Slice` and a runtime length assertion, which was the naive first design before this app's binary parsing needs were considered.

## Open questions / risks
Const-generic array sizes interacting with `core.simd`'s fixed-width vector types (both are "N baked into the type") need a single unified const-generic mechanism, not two similar-but-incompatible ones — flagged as a coordination point with `core.simd`, not yet resolved here.
