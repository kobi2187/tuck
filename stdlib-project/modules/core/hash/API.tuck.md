# core.hash — Tuck translation

## Shape decision
`interface Hashable` plus freeform `pending:` verbs over plain records.
**Compiler-verified**, `./tuck ch`: `OK`, 10/10 `PENDING`.

## The API

```tuck
interface Hashable:
  fn hashOf({self: Self}) -> u64

type FastHash = {state: u64}
type SafeHash = {k0: u64, k1: u64, state: u64}
type SlidingSum = {a: u32, b: u32, windowLen: int}

pending:
  fn newFastHash() -> FastHash
  fn newSafeHash({k0: u64, k1: u64}) -> SafeHash
  fn feedFast({m: FastHash, data: Seq[u8]}) -> FastHash
  fn feedSafe({m: SafeHash, data: Seq[u8]}) -> SafeHash
  fn digestFast({m: FastHash}) -> u64
  fn digestSafe({m: SafeHash}) -> u64
  fn newSlidingSum({over: Seq[u8]}) -> SlidingSum
  fn slideIn({s: SlidingSum, arriving: u8}) -> SlidingSum
  fn slideOut({s: SlidingSum, leaving: u8}) -> SlidingSum
  fn digestSliding({s: SlidingSum}) -> u32
```

## Notes on the translation
- **The `Mixer` concept becomes two concrete types, not one interface.**
  Nim's `Mixer` was structural — anything with `write`/`digest` qualified,
  so `hashOf(x, using = safeHash(key))` could take either algorithm.
  Tuck's overload rule blocks the direct equivalent: two free fns named
  `feed` (one per type) are rejected as duplicate declarations — and per
  the 2026-08-24 ruling (`ROADMAP.md`) that is deliberate, so
  `feedFast`/`feedSafe` and `digestFast`/`digestSafe` are the permanent
  spelling rather than a stopgap. The upside is that a call site says which
  algorithm it uses without the reader checking a type — which for a
  security-relevant choice (fast-but-forgeable vs DoS-resistant) is
  arguably better than the overloaded version.
- **`FastHash`/`SafeHash` naming is kept exactly** — the Nim pass's own
  best rename ("the type name now answers the only question a caller
  has": is this safe against a hostile key?). Nothing about Tuck changes
  that reasoning.
- **Feed functions return the new state** rather than mutating in place,
  per the value-semantics rule (`TUCK-TRANSLATION.md`). Same for
  `slideIn`/`slideOut`. This is more visible churn than Nim's `var`
  parameters, but it's the honest shape.
- `View[byte]` → `Seq[u8]` throughout, per `core.slice`'s finding.
- **`SlidingSum` stays deliberately outside the `Hashable` interface**,
  exactly as the Nim design insisted: it has no final state and a match is
  only ever a *candidate*, confirmed by a real hash. Keeping it out of the
  shared vocabulary is the point, and it survives translation unchanged.
