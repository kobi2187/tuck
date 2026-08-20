# core.cmp

## Purpose
The single comparison mechanism for the entire standard library: `Eq` (equality), `Ord`/`PartialOrd` (total and partial ordering), and the `Ordering` enum they produce — used uniformly by sorting, searching, map keys, and every module above `core` that needs to compare two values of a type.

## Design lineage
Modeled on Rust's `cmp::Ordering` and the `Eq`/`Ord`/`PartialOrd` trait split (separating "always comparable" from "may not be comparable," which correctly models floating point's NaN), with D's `opCmp` operator-overload convention cited in the report as the other influence for how a *single* method can drive both equality and three-way comparison ergonomically. Rust's explicit split was chosen over a single overloaded `opCmp` because the report's Part II survey identifies exactly this partial/total distinction as the source of real defects (Python 2's total-orderability assumption breaking on mixed types; Java's `Comparable` silently misbehaving on NaN-containing `Double`).

## Proposed API
```
enum Ordering { Less, Equal, Greater }

impl Ordering {
    fn reverse(self) -> Ordering;
    fn then(self, other: Ordering) -> Ordering;       // lexicographic chaining
    fn then_with(self, f: impl FnOnce() -> Ordering) -> Ordering;
}

trait Eq {
    fn eq(&self, other: &Self) -> bool;
    fn ne(&self, other: &Self) -> bool { !self.eq(other) }  // default
}

trait PartialOrd: Eq {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering>;  // None: NaN-like cases
    fn lt(&self, other: &Self) -> bool;
    fn le(&self, other: &Self) -> bool;
}

trait Ord: PartialOrd {
    fn cmp(&self, other: &Self) -> Ordering;   // total order, always defined
    fn max(self, other: Self) -> Self;
    fn min(self, other: Self) -> Self;
    fn clamp(self, lo: Self, hi: Self) -> Self;
}

// Free function for building custom sort keys without a full trait impl:
fn by_key<T, K: Ord>(f: impl Fn(&T) -> K) -> impl Fn(&T, &T) -> Ordering;
```

## Key design decisions
- `Eq`/`PartialOrd`/`Ord` are three traits, not one, specifically to make "this type has equality but no total order" (or has a *partial* order, like floats) representable and checkable at compile time, rather than a runtime comparator that can throw or silently misorder — a direct response to the report's named defect category.
- `Ordering::then`/`then_with` exist so multi-key sorts (`sort by priority, then by due date`) compose without hand-written if/else chains — this is the concrete mechanism that makes `core.cmp` usable directly by application-level sort logic, not just internal to `core.slice`'s sort implementation.
- `cmp::Ord` is the *only* mechanism `alloc.map`'s ordered variant and `core.slice::sort`/`binary_search` accept — no module is permitted to define its own bespoke comparator convention (e.g. a raw `-1/0/1` integer return, common in C-derived APIs), enforcing Principle 4 at the type-signature level, not just by convention.

## Validated by applications
- **todo-cli**: named directly in the app's module table for "sort ordering (priority, due date, custom user-defined orders)." This is the primary forcing function for `Ordering::then`/`then_with`: the naive first design considered only single-key `Ord`, but todo-cli's `sort by priority, due date` requirement showed that without chainable ordering, application code would have to duplicate three-way-comparison logic by hand for every multi-key sort, which is exactly the ceremony Principle 3 is meant to eliminate.
- **doc-convert-tester**: round-trip diffing needs `Eq` (not `Ord`) specifically — confirmed the trait split matters in practice, since a document's structural diff never needs an ordering, only equality, and requiring `Ord` (with its total-order proof obligations) for types that only need `Eq` would have been unnecessary ceremony for this app's schema-driven comparisons.
- **archive-cli**: listing and verifying archive entries benefits from a stable, deterministic ordering (e.g. by path) for reproducible `archive list` output and integrity-test diffing; this is a lighter, secondary validation that `Ord` on composite keys (path segments) needs to be derivable rather than hand-written per struct, motivating a future `#[derive(Ord)]`-equivalent at the `alloc`/`std` tooling layer (noted here, implemented above `core`).
- **math-toolkit-cli**: computing `p50`/`p90`/`p99` over a CSV column of `f64` values requires sorting them first, which is exactly the case the report's Part II survey warns about (Java's `Comparable` misbehaving on NaN-containing `Double`) — a malformed or missing cell parsed as `f64::NAN` must not silently scramble the sort order of every other value or produce an out-of-bounds percentile. This is the first app to exercise the `PartialOrd`/`Ord` split specifically on floating-point data rather than structs: `f64` implements `PartialOrd` (NaN correctly yields `None` from `partial_cmp`) but not `Ord`, so the percentile function is forced to make an explicit choice — reject/filter NaN cells before sorting, rather than sort silently succeeding with an ill-defined order — confirming the trait split does the job it was designed for rather than being purely a structs-and-strings concern.

- **diff-patch**: line-equality comparison (`lines_a[i] == lines_b[j]`) drives every cell of the LCS table, a pure `Eq` use with no ordering involved anywhere in the algorithm — a second, independent confirmation (after `doc-convert-tester`) that real comparison-heavy workloads frequently need only `Eq`, and that requiring `Ord`'s total-order proof obligations reflexively wherever two values are compared would have been unnecessary ceremony here too. No change to this module was needed; the trait split already does the job.

## Open questions / risks
Whether derive-style automatic `Ord`/`Eq` generation belongs in `core` itself (as a compiler feature) or is purely a tooling concern above it is unresolved; this module only specifies the traits, not how impls get written.
