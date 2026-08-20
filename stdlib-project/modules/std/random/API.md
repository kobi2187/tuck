# std.random

## Purpose
Seedable, reproducible, non-cryptographic pseudo-random number generators for simulations, sampling, and games — kept in a namespace entirely separate from `std.crypto`'s CSPRNG so the two families of type can never be passed to each other by accident.

## Design lineage
Modeled directly on Go's split between `math/rand`/`math/rand/v2` (fast, seedable, explicitly *not* safe for security use) and `crypto/rand` (OS-backed CSPRNG, no seeding, no reproducibility) — two packages with deliberately non-overlapping types and no shared interface, cited in the report as "a real precedent for exactly this separation." `std.random` mirrors `math/rand`'s shape; `std.crypto::rng` (see that module) mirrors `crypto/rand`'s.

## Proposed API
```
// The core PRNG type. Deliberately NOT named `Rng` (too easy to confuse with std.crypto::rng)
// and does not implement any trait std.crypto's key/nonce-generation code accepts.
struct Prng;
impl Prng {
    fn seeded(seed: u64) -> Prng;             // deterministic — same seed, same sequence, forever (stable algorithm)
    fn from_entropy() -> Prng;                 // seeded from the OS at construction time, but still NOT a CSPRNG afterward
    fn next_u32(&mut self) -> u32;
    fn next_u64(&mut self) -> u64;
    fn next_f64(&mut self) -> f64;             // uniform [0, 1)
    fn range(&mut self, lo: i64, hi: i64) -> i64;      // uniform [lo, hi)
    fn bool(&mut self, p: f64) -> bool;                 // Bernoulli, P(true) = p
}

// Sampling helpers, generic over any Prng — composes with core.iter/alloc collections.
mod sample {
    fn choose<'a, T>(rng: &mut Prng, items: &'a [T]) -> Option<&'a T>;
    fn shuffle<T>(rng: &mut Prng, items: &mut [T]);                    // Fisher-Yates, in place
    fn weighted<'a, T>(rng: &mut Prng, items: &'a [(T, f64)]) -> Option<&'a T>;
}

// Named, documented algorithm — reproducibility across versions of std is a stated guarantee for `seeded()`.
enum Algorithm { Pcg64, Xoshiro256 }
fn with_algorithm(seed: u64, alg: Algorithm) -> Prng;   // Prng::seeded uses a fixed default; this pins a specific one
```

## Key design decisions
- **No function or type in `std.random` accepts or produces `std.crypto::aead::Key` or any other `std.crypto` secret type, and vice versa — the separation is enforced by having genuinely disjoint type signatures, not by a naming convention alone.** A caller cannot pass a `Prng` where `std.crypto::kdf`/`aead`/`x25519` expect randomness, because those functions only call into `std.crypto::rng` internally and never accept caller-supplied randomness as a parameter at all — this closes off the entire "used `math/rand`-equivalent for a key" bug class at the type-signature level, not just by documentation.
- **`Prng::seeded`'s output sequence is a *stability guarantee*, not an implementation detail** — the same seed must produce the same sequence across std versions (achieved by pinning the default algorithm and only changing it via the explicit, named `with_algorithm`), because reproducible simulations and reproducible test fixtures both depend on it; this is the opposite guarantee from `std.crypto::rng`, which promises nothing about reproducibility and would be actively wrong to promise it.
- **`from_entropy()` still returns a plain `Prng`**, seeded unpredictably at construction time but with an algorithm and internal state that are not designed to resist an adversary who observes outputs and wants to predict future ones — the type is identical to `seeded()`'s, and its doc comment says outright "do not use for anything security-sensitive," reinforcing the separation even at the one call site that superficially resembles a CSPRNG.
- **`sample::weighted`/`choose`/`shuffle` are free functions taking `&mut Prng`, not methods on a collection type** — keeping the "which RNG did this call use" always visible at the call site (`sample::shuffle(&mut prng, &mut deck)`), rather than a `deck.shuffle()` extension method that could hide which generator (crypto or non-crypto) is actually backing it.

## Validated by applications
- **cli-hangman**: the module's primary and defining exercise — `Prng::from_entropy()` + `sample::choose` for uniform random word selection is the app's core validation that non-crypto randomness is both the correct choice (no security property is needed for picking a word) and ergonomically the *easy* choice, not requiring the app to reach past `std.crypto` accidentally; the app's profile explicitly frames this as validating the crypto/non-crypto separation, and there is no code path by which `cli-hangman` could accidentally end up depending on `std.crypto` at all.
- **secrets-vault**: the direct contrast case — the app must use `std.crypto::rng`, never `std.random`, for generated-password charset sampling, and the type-level separation described above means a reviewer (or a future maintainer skimming imports) can see at a glance from `use std::random::Prng` appearing nowhere in the vault's password-generation code that the right generator was used, rather than having to audit call-site logic to confirm it.
- **todo-cli**: uses `std.random` nowhere (task IDs are UUIDs generated via `std.crypto::rng` for global uniqueness guarantees, not `std.random`) — a useful boundary check that even a "just need some randomness" use case (a UUID) correctly reaches for the CSPRNG when uniqueness/collision-resistance is actually the real requirement, not raw unpredictability.

## Open questions / risks
Whether `Prng` should be `Send` and cheaply cloneable/splittable for parallel simulation workloads (spawning independent, non-overlapping streams per worker, as PCG's stream-selection feature supports) is unaddressed by any of the eleven apps and left open for a future numerically-heavy consumer to motivate.
