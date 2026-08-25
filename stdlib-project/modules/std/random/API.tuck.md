# std.random — Tuck translation

## Shape decision
Freeform `pending:` over a `Dice` record. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type Dice = {state: u64, inc: u64}

pending:
  fn newDice({seed: u64}) -> Dice
  fn newDiceFromOs() -> Dice [io]
  fn rollRange({d: Dice, low: i64, high: i64}) -> {d: Dice, value: i64}
  fn rollFloat({d: Dice}) -> {d: Dice, value: float}
  fn chance({d: Dice, probability: float}) -> {d: Dice, yes: bool}
  fn pick[T]({d: Dice, items: Seq[T]}) -> {d: Dice, value: T}?
  fn pickWeighted[T]({d: Dice, items: Seq[T], weights: Seq[float]}) -> {d: Dice, value: T}?
  fn shuffle[T]({d: Dice, items: Seq[T]}) -> {d: Dice, items: Seq[T]}
  fn sample[T]({d: Dice, items: Seq[T], count: int}) -> {d: Dice, items: Seq[T]}
  fn fillBytes({d: Dice, count: int}) -> {d: Dice, bytes: Seq[u8]}
  fn gaussian({d: Dice, mean: float, stddev: float}) -> {d: Dice, value: float}
```

## The one thing that gets notably worse in translation

**Every call has to hand the generator back.** A PRNG is *definitionally*
stateful — each draw advances the state — so under value semantics every
verb returns `{d: Dice, value: ...}` and the caller re-binds:

```tuck
var d = {seed: 42} newDice
let r = d.rollRange {low: 1, high: 6}
d = r.d                      # or: d ..rollRange {low: 1, high: 6}
```

The Nim design's `d.roll(1..6)` with `var Dice` reads better. This is the
same friction as `alloc.vec`'s mutators, but more grating because the
*payload* (the number you wanted) and the *bookkeeping* (the advanced
generator) come back together in one record.

**Alternative worth considering:** make `Dice` an `object` and use
`self ..state` mutation, which is legal for object members (rule #11 —
"state the callee OWNS"). That gives `d.roll {low: 1, high: 6} -> i64` with
the state update hidden where it belongs. Verified as a mechanism in
`TokenIssuer` (`TUCK-TRANSLATION.md`), and it's likely the right shape
here — recorded rather than applied, since it changes the module's whole
spelling and the same question is open for `alloc.vec`.

## Notes
- **`gaussian` is new**, per `COMPARISON.md`'s finding that `std.random`
  had no non-uniform distributions while Python's `random` ships several.
  One function, not a subsystem.
- **`newDiceFromOs` is `[io]`; `newDice(seed)` is not.** That split is
  load-bearing: a seeded generator must be reproducible and pure, which is
  what makes `diff-patch`'s property tests replayable.
- **The "deliberately shares NO type or proc with `std.crypto`" rule
  holds.** `fillBytes` is for test fixtures; keys and nonces come from
  `std.crypto`'s own CSPRNG. Worth restating in the docs since the two
  functions look interchangeable and aren't.
- `roll` → `rollRange`/`rollFloat` because free functions can't overload
  (`[TK-TY02]`).
