# core.hash

## Purpose
A `Hash` trait every hashable type implements once, plus a couple of concrete, allocation-free hash algorithms — FNV (fast, non-cryptographic, for trusted keys) and a SipHash core (DoS-resistant, for attacker-influenced keys) — that `alloc.map`'s hash-based variant is built on.

## Design lineage
Modeled on Rust's `core::hash` (a `Hash` trait with a single `hash(&self, state: &mut impl Hasher)` method, decoupled from any specific algorithm, so the same trait impl works whether the backing hasher is FNV, SipHash, or a custom one) — chosen because it is the cleanest separation in the survey between "how a type contributes its bits to a hash" and "which algorithm combines those bits," letting `alloc.map` swap algorithms (e.g., default to SipHash for public-facing keys, opt into FNV for trusted internal keys) without touching a single `Hash` impl.

## Proposed API
```
trait Hasher {
    fn write(&mut self, bytes: slice::Slice<u8>);
    fn write_u64(&mut self, value: u64);        // provided, calls write() on the bytes
    fn finish(&self) -> u64;
}

trait Hash {
    fn hash<H: Hasher>(&self, state: &mut H);
}

struct FnvHasher { /* opaque: FNV-1a state, fast, not DoS-resistant */ }
impl FnvHasher {
    fn new() -> Self;
}
impl Hasher for FnvHasher { /* ... */ }

struct SipHasher13 { /* opaque: SipHash-1-3 core, keyed, DoS-resistant */ }
impl SipHasher13 {
    fn new_with_keys(k0: u64, k1: u64) -> Self;
}
impl Hasher for SipHasher13 { /* ... */ }

// Convenience: hash any Hash value with a chosen algorithm in one call, no
// manual Hasher plumbing for the common case:
fn hash_one<T: Hash, H: Hasher + Default>(value: &T) -> u64;

// Added (backup-sync) — an Adler-32-style rolling checksum for block-level
// delta diffing over a sliding byte window. Deliberately NOT a Hasher impl:
// see "RollingChecksum: a different API shape, not just another algorithm"
// below for why.
struct RollingChecksum { /* opaque: sum + weighted-sum accumulators, plus
                             current window length; no byte buffer owned —
                             the caller owns the sliding window's storage */ }

impl RollingChecksum {
    fn new() -> Self;                                    // empty window, digest() == 0
    fn from_window(window: slice::Slice<u8>) -> Self;     // O(window size): one-time seed at a block boundary

    fn roll_in(&mut self, new_byte: u8);                  // O(1): extend the window by one byte at the end
    fn roll_out(&mut self, old_byte: u8);                 // O(1): shrink the window by one byte at the start
                                                            // (caller supplies the exact byte value leaving —
                                                            // this type does not store window contents itself)

    fn digest(&self) -> u32;                               // current checksum for whatever's in the window now;
                                                            // valid to call after every single roll_in/roll_out,
                                                            // not just at a "final" state (there isn't one)
    fn window_len(&self) -> usize;
}
```

## Key design decisions
- `Hash` is decoupled from any specific algorithm (unlike, e.g., baking a hash function directly into `==`/comparison as some languages do) so the same derived `Hash` impl on a struct works under FNV in a performance-critical, trusted-key context and under SipHash where keys come from untrusted network input — one trait, algorithm chosen at the call site or by the container.
- Both FNV and SipHash are included as concrete algorithms in `core` itself (not left to `alloc`/`std` or an external crate) because `alloc.map`'s default hash-based variant needs a working, dependency-free hasher available at the tier directly below it — an earlier draft left algorithm choice entirely to `alloc`, but that would have made `alloc.map`'s minimum viable dependency chain reach outside `core`/`alloc`, violating Principle 1's tier-by-weakest-dependency rule.
- SipHash is the *default* for `alloc.map`, not FNV, specifically because the report's survey (and this design's own applications, chat-server especially) treats hash-flooding DoS as a real threat for any map keyed by attacker-influenced data; FNV remains available as an explicit opt-in for cases where keys are trusted and raw speed matters more (e.g. `mp3-player`'s internal indexing).
- **Revision (backup-sync): `RollingChecksum` — a different API shape than `FnvHasher`/`SipHasher13`, not just a third algorithm option.** Every hasher this module offered before now shares one contract, inherited directly from the `Hasher` trait: bytes go in via `write()` any number of times, in one direction, and the digest is read out via `finish()` once, at the end — an append-only, single-pass, terminal-state machine. That shape is precisely what a sliding-window rolling checksum cannot use, for two independent reasons, not one. First, mechanically: `write()`/`finish()` has no notion of a byte *leaving* the hashed region, only of more bytes arriving, so there is no way to express "drop the oldest byte, keep the rest" without recomputing from scratch — an O(window size) operation repeated at every slide position, which is exactly the O(n·window) blowup `backup-sync`'s delta mode exists to avoid. Second, and more fundamentally: FNV's and SipHash's whole reason for existing is *avalanche* — a one-bit input change should unpredictably flip roughly half the output bits, which is what makes them usable as hash-table keys (good bucket distribution) and, for SipHash, DoS-resistant (an attacker can't predict-and-collide). That mixing is not invertible: once a byte has been folded into 64 bits of scrambled state, there is no O(1) way to un-mix specifically *that* byte back out while leaving the rest of the state validly representing the remaining window. `RollingChecksum` is only capable of O(1) `roll_in`/`roll_out` because it deliberately gives up avalanche entirely — it is a simple additive/weighted-sum accumulator (Adler-32's structure), and that same simplicity is exactly why it must never be reached for as a general-purpose bucket hash or content identity (its output is easy to predict and construct collisions against on purpose). It is not a `Hasher` impl — plugging it into the existing `Hash`/`Hasher` machinery would misleadingly suggest it composes with `#[derive(Hash)]`-style types the way FNV/SipHash do, when its actual contract (incremental, removable, no terminal state, byte-window-only, not attacker-resistant) is a different thing wearing a superficially similar "produces a `u32`" surface. It stays in `core.hash` rather than `std.crypto` for the same mechanical reason already established by the `core.hash`-vs-`std.crypto` boundary rule above: its output is never compared for identity across a trust boundary or relied on for collision resistance — a rolling-checksum match is only ever a *candidate*, cheaply computed over millions of sliding positions, that a strong hash (`std.crypto` or even `SipHasher13`) then confirms before actually treating two blocks as identical — mirroring rsync's own real two-tier design (weak rolling checksum first, strong checksum to confirm) rather than inventing a third boundary rule.
- **Revision (git-lite): the `core.hash` vs. `std.crypto::hash` boundary is stated explicitly, not left to be inferred.** The rule is single-sentence and mechanical, not a judgment call per app: if the hash's output is ever compared for *equality across trust boundaries, persisted as an identity/address, or relied on for collision resistance*, it is a `std.crypto` job (SHA-256/BLAKE3/SHA3), full stop — `core.hash`'s `FnvHasher`/`SipHasher13` are explicitly documented as **unsuitable for content addressing** (FNV has no collision resistance at all; even SipHash, though keyed and DoS-resistant, is a MAC-shaped PRF, not a general collision-resistant digest, and is not sized or vetted for that role). The inverse rule is equally explicit: if the hash exists purely to scatter keys across an in-memory bucket array and the *worst case of a collision* is degraded lookup performance (not a security or correctness failure), it belongs in `core.hash`, because `std.crypto`'s cryptographic hashes are 10-100x slower per byte and that cost is pure waste on a hot in-memory lookup path with no adversarial-identity requirement. `git-lite` is kept as the canonical worked example in this doc specifically because it is the one app that needs both, side by side, over the same underlying data: `alloc.map<Sha256Digest, CommitObject>`'s bucket hashing uses `core.hash` (the map key is already a well-distributed cryptographic digest, so even FNV over it is fine and fast), while the digest *itself* — the thing that makes two commits with identical content collide on purpose — is computed once via `std.crypto::hash::sha256`, never via `core.hash`. The two modules are not competing options for "hashing" in general; `core.hash` answers "how do I bucket this key fast" and `std.crypto` answers "what uniquely and unforgeably identifies this content," and no type in either module is meant to answer both questions.

## Validated by applications
- **chat-server**: nickname → connection and room → client-list registries are keyed by strings that arrive directly from network clients — exactly the attacker-influenced-key scenario SipHash exists for. This is the concrete case that settled the "SipHash by default, FNV opt-in" decision: a naive first design defaulting every `alloc.map` to FNV (simpler, faster, and sufficient for todo-cli's trusted local data) would leave chat-server's registries vulnerable to a hash-flooding DoS from a malicious client sending many colliding nicknames, which this app's "many concurrent connections" threat model makes a real, not theoretical, concern.
- **todo-cli**: indexing tasks by UUID and tag is the trusted-key counterpart — UUIDs are locally generated, not attacker-supplied, so this app is the validation that `core.hash` must let performance-sensitive, trusted-key use cases opt into FNV explicitly rather than paying SipHash's (modest but nonzero) per-key overhead unconditionally, confirming the two-algorithm design earns its complexity rather than SipHash-only being "safe enough for everyone."
- **podcast-subscriber**: GUID-based episode dedup across many feeds is a high-volume, trusted-key (feed-generated GUIDs, not directly attacker-chosen in the threat model this app assumes) hashing workload, reinforcing that `core.hash`'s algorithm choice needs to be a per-map decision, not a global stdlib-wide default, since this app's performance profile (poll many feeds, dedup many GUIDs) leans toward FNV while chat-server's leans toward SipHash for the same underlying `alloc.map` type.
- **git-lite**: the deliberate contrast case the module needed. The commit graph's `alloc.map`-based parent-pointer lookups (`hash → CommitObject`) hash an already-cryptographically-random key, so `core.hash`'s FNV/SipHash is the right (and only sane, performance-wise) tool there; object *identity* — the SHA-256 that names a blob/tree/commit and is what "content-addressed" means — is exclusively `std.crypto::hash::sha256`'s job and never touches this module. The app's own "Anticipated API stress points" section names the risk that two hash modules in two tiers looks confusing from the outside; this module's revision above (see Key design decisions) is the direct resolution: the boundary is mechanical (identity/collision-resistance/cross-trust-boundary comparison → `std.crypto`; in-memory bucket scatter → `core.hash`) and git-lite is now the doc's worked example precisely because it is the one app that needs to draw that line explicitly in its own code rather than only ever touching one side of it.

- **backup-sync**: `--delta` mode's whole value proposition — detecting which fixed-size blocks of a large, mostly-unchanged file actually differ without recopying the entire file — depends on scanning every possible window offset within the new file's content looking for a block whose rolling checksum matches one already recorded from the old file. Doing that with a fixed-input hasher would mean recomputing a full hash at every byte offset (O(file size × block size)); `RollingChecksum::roll_in`/`roll_out` make each slide O(1) (O(file size) total), which is the entire algorithmic point of rsync's delta-transfer approach and the concrete forcing function for adding this type. A `RollingChecksum::digest()` collision is treated as a candidate match only — the app profile's own design already calls for `std.crypto` content hashing to resolve ambiguous cases, and the same pattern applies here: a rolling-checksum hit is confirmed against a stronger hash of the candidate block before it's trusted, never treated as identity on its own.

## Open questions / risks
Whether `alloc.map`'s default should be SipHash-always (safe by default, opt-out for speed) or context-dependent is a policy decision this module doesn't itself resolve — it only ensures both algorithms are available and cheaply swappable; the default is `alloc.map`'s call, not `core.hash`'s.
