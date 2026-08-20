# alloc.set

## Purpose
Hash-based and ordered (tree-based) set variants for membership testing and de-duplication, sharing `alloc.map`'s hasher/comparison machinery rather than reimplementing it.

## Design lineage
Modeled on **Rust's `HashSet<T>`/`BTreeSet<T>`** (the report's chosen precedent for offering both an unordered, average-O(1) variant and an ordered, O(log n)-but-always-sorted variant under one conceptual family) and **C++'s `set`/`unordered_set`** for the same hash-vs-tree split. The key design choice — implement `HashSet` as a thin wrapper over `alloc.map::HashMap<T, ()>` — follows directly from the report's Principle 3 (small composable interfaces beat concrete classes): a set is a map with a unit value, not a parallel data structure.

## Proposed API
```
struct HashSet<T, H = DefaultHasher> { inner: HashMap<T, (), H> }   // literal composition, not reimplementation
struct TreeSet<T> { .. }                                             // ordered, built on core.cmp::Ord — no hasher needed

impl<T: Hash + Eq> HashSet<T> {
    fn new() -> Self;
    fn new_in(a: &dyn Allocator) -> Self;
    fn with_capacity_in(n: usize, a: &dyn Allocator) -> Self;   // added for spellchecker, see Key design decisions
    fn insert(&mut self, v: T) -> Result<bool, AllocError>;   // true if newly inserted
    fn remove(&mut self, v: &T) -> bool;
    fn contains(&self, v: &T) -> bool;
    fn len(&self) -> usize;
    fn iter(&self) -> core.iter::Iter<&T>;
    fn union<'a>(&'a self, other: &'a Self) -> core.iter::Iter<'a, &'a T>;
    fn intersection<'a>(&'a self, other: &'a Self) -> core.iter::Iter<'a, &'a T>;
    fn difference<'a>(&'a self, other: &'a Self) -> core.iter::Iter<'a, &'a T>;
    fn allocator(&self) -> &dyn Allocator;
}

impl<T: Ord> TreeSet<T> {
    fn new_in(a: &dyn Allocator) -> Self;
    fn insert(&mut self, v: T) -> Result<bool, AllocError>;
    fn remove(&mut self, v: &T) -> bool;
    fn contains(&self, v: &T) -> bool;
    fn iter(&self) -> core.iter::Iter<&T>;                    // always yields in sorted order — the reason to pick TreeSet over HashSet
    fn first(&self) -> Option<&T>;
    fn last(&self) -> Option<&T>;
    fn range(&self, r: impl RangeBounds<T>) -> core.iter::Iter<&T>;
}
```

## Key design decisions
- **`HashSet<T>` is literally `HashMap<T, ()>` internally**, not a separately-implemented structure that happens to share a name — this is a direct application of Principle 3 and keeps the set's allocator ergonomics, hasher-swap story, and iteration-order caveat identical to the map's by construction rather than by discipline (two implementations of the same idea inevitably drift).
- **Two set types, chosen by need, not one type with a "sorted" flag.** `TreeSet` exists only when insertion-order-independent *sorted* iteration is actually required (`range()` queries, `first()`/`last()`); everything else should default to `HashSet`. Making this a type-level choice rather than a runtime flag means the cost (O(log n) vs. amortized O(1)) is visible in the signature a caller writes, not hidden behind a constructor argument.
- **Set-algebra methods (`union`/`intersection`/`difference`) return lazy `core.iter` iterators, not new allocated sets**, by default — consistent with `core.iter`'s laziness philosophy and avoiding a surprise allocation in what looks like a read-only query; a caller who wants a materialized set calls `.collect_into(HashSet::new_in(&a))` explicitly, keeping the allocation visible at the call site per Principle 2.
- **Revision (spellchecker): added `HashSet::with_capacity_in`.** Because `HashSet<T>` is literally `HashMap<T, ()>` internally, it should have inherited `alloc.map`'s existing `with_capacity_in` for free, but the Proposed API only ever exposed `new()`/`new_in` — an oversight this app's dictionary-loading path surfaces concretely: inserting 100k+ words one at a time into a set that starts at default/minimum capacity forces on the order of a dozen-plus incremental rehash-and-reallocate cycles it wouldn't need if the target size were known up front (which it is — dictionary word counts are knowable from the file before the load loop starts). This isn't a new capability so much as closing a gap between what the composition (`HashSet` over `HashMap`) already implies and what the Proposed API actually listed.

## Validated by applications
- **cli-hangman**: `HashSet<char>` for guessed letters is close to the smallest possible real use of this module — `insert`, `contains`, done. As the deliberate control-case app, this validated that the common case really does stay this simple: no allocator ceremony visible (`HashSet::new()`), no hasher tuning needed, no set-algebra methods required. If this app had needed anything more from `alloc.set`, that would itself have been a signal the API had too much required setup for its weight class.
- **todo-cli**: tags on a task (`+errand`, `+urgent`) are naturally a `HashSet<String>` per task, and the filter query language's multi-tag matching (`+urgent +home`) is a direct `intersection`/`contains`-style check against the query's tag set — this validated that set-algebra operations need to work against borrowed, non-owned sets (`&HashSet<String>`) since building a fresh set per filter evaluation would be wasteful for a command run many times interactively.
- **log-grep**: `.gitignore`-style exclude-pattern matching benefits from a `HashSet<PathBuf>`-style dedup of already-visited directories when following symlinks during tree walking, guarding against symlink cycles — a smaller but real validation that the module composes cleanly with `sys.fs`'s tree-walking without needing anything set-specific added.
- **spellchecker**: the dictionary itself — a `HashSet<String>` (or `HashSet<&str>` over an interned/mmapped word list) of 100k+ entries, built once at startup and then queried with `contains()` on every token of every document processed, a load-once/query-many-times access pattern this module hadn't previously been stress-tested against. The access pattern itself validates cleanly: `contains()` on `HashSet<T> = HashMap<T, ()>` is the map's `get`/`contains_key` under the hood, which is already validated at comparable or larger scale by `kv-store-server` and `chat-server`'s hot-path maps, so per-lookup cost at this scale is not a new risk. What the scale *did* expose is the bulk-load gap fixed above (`with_capacity_in`); with that addition, this app's usage is otherwise unremarkable — no set-algebra operations needed, `insert`-during-load then `contains`-during-scan is the whole story, which is itself a useful confirmation that a large, static, read-mostly set doesn't need anything beyond what a small, dynamic one does.

## Open questions / risks
- Whether `TreeSet` pulls its own weight as a distinct `alloc`-tier module versus being folded entirely into `alloc.map`'s documentation (as a `TreeMap<T,()>` alias, mirroring the `HashSet`-over-`HashMap` composition) is open — no surveyed app exercised `TreeSet` directly, which is itself a signal worth flagging: it may belong at `std` instead, added only when a real ordered-set use case appears, per Principle 5.
