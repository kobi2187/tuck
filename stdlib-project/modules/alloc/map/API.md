# alloc.map

## Purpose
A hash-based key/value map for the common case of unordered, average-O(1) lookup/insert/delete, sharing one interface with `alloc.set`'s hash variant (a set is modeled as a map to `()`).

## Design lineage
Modeled on **Rust's `HashMap<K, V>`** (open addressing, `Hash`/`Eq` from `core.hash`/`core.cmp` — reusing the report's Principle 4 comparison/hash mechanisms rather than a bespoke per-collection trait) and **Go's built-in `map`** for the "this should be usable with almost no ceremony" bar the common case must clear. C++'s `unordered_map` informs the bucket/load-factor tuning knobs kept present but optional.

## Proposed API
```
struct HashMap<K, V, H = DefaultHasher> { .. }   // H is core.hash-compatible, defaults to a DoS-resistant SipHash-style hasher

impl<K: Hash + Eq, V> HashMap<K, V> {
    fn new() -> Self;                                        // default allocator, default hasher
    fn new_in(a: &dyn Allocator) -> Self;
    fn with_capacity_in(n: usize, a: &dyn Allocator) -> Self;
    fn with_hasher_in(h: H, a: &dyn Allocator) -> Self;       // e.g. a faster non-DoS-resistant hasher for trusted keys

    fn insert(&mut self, k: K, v: V) -> Result<Option<V>, AllocError>;  // returns previous value if any
    fn get(&self, k: &K) -> Option<&V>;
    fn get_mut(&mut self, k: &K) -> Option<&mut V>;
    fn remove(&mut self, k: &K) -> Option<V>;
    fn contains_key(&self, k: &K) -> bool;
    fn entry(&mut self, k: K) -> Entry<K, V>;                 // insert-or-modify without double lookup

    fn len(&self) -> usize;
    fn clear(&mut self);
    fn iter(&self) -> core.iter::Iter<(&K, &V)>;
    fn keys(&self) -> core.iter::Iter<&K>;
    fn values(&self) -> core.iter::Iter<&V>;
    fn retain(&mut self, f: impl FnMut(&K, &mut V) -> bool);  // bulk conditional removal, single pass
    fn allocator(&self) -> &dyn Allocator;
}

enum Entry<'a, K, V> { Occupied(OccupiedEntry<'a, K, V>), Vacant(VacantEntry<'a, K, V>) }
impl<'a, K, V> Entry<'a, K, V> {
    fn or_insert(self, default: V) -> Result<&'a mut V, AllocError>;
    fn or_insert_with(self, f: impl FnOnce() -> V) -> Result<&'a mut V, AllocError>;
}
```

## Key design decisions
- **Hasher is a type parameter with a safe default, not a hardcoded algorithm.** The default is DoS-resistant (randomized-seed, SipHash-family) because a hash map keyed by attacker-controlled input (HTTP headers, chat nicknames) is a known real-world denial-of-service vector; `with_hasher_in` is the escape hatch for hot paths with trusted keys that want a faster non-cryptographic hash (e.g. `core.hash`'s FNV). This mirrors Rust's resolved design rather than Go's (which historically had no public hasher-swap story) — a deliberate "steal the better one" call per the report's Part II methodology.
- **`entry()` API to avoid double lookups**, matching Rust's precedent — chosen specifically because `todo-cli`'s tag-indexing and `chat-server`'s room-registry both do read-then-conditionally-write patterns where a naive `if !contains_key { insert }` would hash twice.
- **Iteration order is explicitly unspecified** (unlike insertion-ordered maps in some languages) — this is a real constraint communicated up front rather than an accident, so no app is tempted to rely on it; where iteration order matters (a stable listing), the app is expected to sort explicitly via `core.cmp`, keeping "one comparison mechanism used everywhere" (Principle 4) rather than the map inventing its own ordering story.
- **Allocator threading is identical to `alloc.vec`/`alloc.string`** (`new()`/`new_in(&a)` pair) — the map's internal bucket array is itself effectively a `Vec`-like buffer, so this isn't a new pattern to learn, just the third application of the same one.
- **Revision (kv-store-server):** added `retain(&mut self, f: impl FnMut(&K, &mut V) -> bool)` to the Proposed API. This was previously an explicitly *deferred* open question ("none of the surveyed apps needed it, flagged rather than speculatively added"); `kv-store-server`'s active TTL expiration is the concrete forcing function — a background sweep that must walk the whole map and evict expired entries in one pass, under the same lock the request path contends on, is exactly the "bulk conditional removal" case `retain` exists for. The alternative (collect expired keys via `iter()` into a `Vec`, then call `remove()` per key) does two full traversals and a temporary allocation for what should be a single pass with no extra allocation — unacceptable on a hot map already under sustained mutation pressure. `retain` is specified as single-pass and allocation-free (beyond whatever in-place bucket compaction the implementation already does for `remove`), matching `alloc.vec::retain`'s existing signature shape for consistency (Principle 4).

## Validated by applications
- **chat-server**: two maps under real concurrent load — `room name -> Vec<ClientHandle>` and `nickname -> ClientHandle` — accessed from many per-connection handler tasks. This app is what validated `entry()` as a first-class method rather than a nice-to-have: nickname registration is check-then-insert under a lock, and a double-hash naive implementation would double the lock-hold time under contention, exactly the kind of `sys.sync` contention risk the report's chat-server profile calls out.
- **todo-cli**: an index of `UUID -> Task` plus a secondary `tag -> Vec<UUID>` structure for the filter query language; this app is what confirmed the map needs efficient `get`/`remove` by a non-trivial key type (`UUID`, a fixed-size byte array) and validated that `Hash`/`Eq` coming from `core.hash`/`core.cmp` (rather than the map defining its own) means any user type automatically works as a key with zero extra boilerplate — a direct payoff of Principle 4.
- **podcast-subscriber**: GUID-based episode dedup on every poll (`seen: HashMap<Guid, EpisodeState>`) is the map's namesake use case — a straightforward validation with no surprises, which is itself useful signal that the design doesn't need a special "dedup set" escape hatch beyond what `contains_key`/`entry` already provide.
- **process-supervisor**: a `process-name -> ProcessHandle/state` registry, updated on every spawn/restart/exit-reap and read on every `supervisorctl status` control-socket request — a small, low-cardinality, trusted-key map (names come from the supervisor's own config file, not a network peer), which is a light, unsurprising validation: `get`/`entry` (state transition on crash: look up, update restart-count and backoff timer in place) cover the whole access pattern with no new requirement, reinforcing that the design's common case stays ceremony-free even for a map sitting at the center of a daemon's control-plane state.
- **git-lite**: the commit graph (`hash -> CommitObject`, walked via parent pointers for `log`) and each tree object's `name -> hash` entries are both plain `HashMap` usage — but this app is the one that makes the module's `core.hash`-vs-`std.crypto` boundary concrete rather than abstract: the map's *keys* here are already-computed SHA-256 digests (from `std.crypto`, for content-identity), while the map's own internal bucket hashing runs through `core.hash` (FNV is fine — the key is already uniformly distributed, and there's no DoS-relevant untrusted-input path once the object is stored under its own hash). No change to `alloc.map` was needed; this is a clean secondary validation of `with_hasher_in`'s trusted-key opt-out path, now applied to a cryptographic-digest key type rather than a UUID (`todo-cli`) or a plain string (`podcast-subscriber`).
- **kv-store-server**: the single `String -> Value` map that backs every `SET`/`GET`/`DEL`/`INCR` command is on the hot path of every client request under sustained, high-mutation-rate concurrent load — a materially different stress profile than `chat-server`'s comparatively low-frequency room/nickname registries or `todo-cli`/`podcast-subscriber`'s largely-read-after-load maps. This is the app that confirmed the existing design's performance-relevant choices (default DoS-resistant hasher, `entry()` to avoid double lookups, unspecified iteration order leaving room for internal bucket-layout optimization) hold up rather than needing a "fast path" variant, *and* it is the direct forcing function for adding `retain` (see Key design decisions) to serve active TTL expiration without a double traversal. It's also a live test of iteration-during-mutation: `retain`'s single-method contract (the map visits and can remove-in-place within one call) sidesteps the classic "mutate a collection while iterating it" hazard entirely, rather than requiring the caller to reason about iterator invalidation against a manually interleaved `iter()` + `remove()` pattern.

## Open questions / risks
- ~~Whether `HashMap` should expose a `retain(f)` method...~~ **Resolved by kv-store-server** — see the Revision note above; `retain` is now part of the Proposed API.
