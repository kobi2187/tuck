# core.num — Tuck translation

## Shape decision
Freeform `pending:` verbs. **Compiler-verified**, `./tuck ch`: `OK`, 15/15
`PENDING`.

## The finding: two-thirds of this module is a language feature

The Nim design's centrepiece was three parallel arithmetic families —
`addClamped`/`subClamped`/`mulClamped`, `addWrapped`/`mulWrapped`, and
`tryAdd`/`trySub`/`tryMul`/`tryDiv` — because Nim has no way to say
"this type saturates" once.

**Tuck does.** Overflow behaviour is a *type attribute*:

```tuck
type SafeRPM   = u16 [saturating]   # clamps at 65535
type PacketSeq = u8  [wrapping]
```

`[saturating]` is run-gated on both backends (`examples/40-saturating.tuck`:
`70000 SafeRPM` → 65535, where wrapping would give 4464), and the clamp runs
on a *wider intermediate*, so a value is checked against the type's real
bounds rather than after it has already wrapped. An overflow attribute also
implies `distinct`.

So the whole `Clamped`/`Wrapped` vocabulary disappears — not renamed,
**deleted**. Where the Nim design wrote `addClamped(a, b)` at every call
site, Tuck declares the intent once on the type and every ordinary `+`
obeys it. That is strictly better: the Nim version could be forgotten at
one call site out of twenty; the Tuck version cannot.

⚠️ **The feature is not finished, and this file is written against where
it's going, not only where it is.** Only `[saturating]` is actually
run-gated on both backends. `[wrapping]` and `[trapping]` are
**declaration-only — no behavioural test** (`LANGUAGE-OVERVIEW.md` §11
says so outright), and `~T` lossy conversion is "named as a future ruling
only" (§17). So `type PacketSeq = u8 [wrapping]` below parses and declares
intent, but nothing yet proves the wrap happens. Treat the attribute
vocabulary as the intended design — per direct guidance to write against
the fixed language — while knowing two-thirds of it is currently untested
rather than merely unimplemented.

**One real semantic difference to know:** the clamp is a **store-guard, not
per-operator**. `a + b + c` on a `[saturating]` type clamps when the result
is stored, not after each operator. The Nim design's per-call spelling made
each step clamp. For a chain that overflows only transiently, the two give
different answers — Tuck's is usually the wanted one, but it is a
difference, not a pure win.

**What survives:** the `try*` family. `tryAdd` returning `i64?` still earns
its place, because "there is no valid answer" (overflow *or* divide-by-zero)
is a different question from "clamp it for me", and `?T` is the natural
carrier. `[trapping]` exists as a third attribute but has **no behavioural
test** (declaration-only, per `LANGUAGE-OVERVIEW.md` §11), so `try*` is
also the only *tested* way to detect overflow rather than absorb it.

## The API

```tuck
type ByteOrder:
  | Big
  | Little

type SafeRPM = u16 [saturating]
type PacketSeq = u8 [wrapping]

pending:
  fn tryAdd({a: i64, b: i64}) -> i64?
  fn trySub({a: i64, b: i64}) -> i64?
  fn tryMul({a: i64, b: i64}) -> i64?
  fn tryDiv({a: i64, b: i64}) -> i64?

  fn toBytes({value: u64, order: ByteOrder}) -> Seq[u8]
  fn fromBytes({bytes: Seq[u8], order: ByteOrder}) -> u64?

  fn hasBit({x: u64, at: int}) -> bool
  fn withBit({x: u64, at: int}) -> u64
  fn withoutBit({x: u64, at: int}) -> u64
  fn flipBit({x: u64, at: int}) -> u64
  fn countBits({x: u64}) -> int
  fn lowestSetBit({x: u64}) -> int?
  fn highestSetBit({x: u64}) -> int?
  fn onlyBit({x: u64}) -> int?
  fn setBits({x: u64}) -> Seq[int]
```

## Notes
- **The bitset half survives almost unchanged** — it was already the Nim
  pass's best work (`lowestSetBit: Index?` instead of the
  "returns bit-width as a not-found sentinel" trap; `onlyBit` for
  sudoku's naked single in one call). All of it translates directly.
- **`setBit`/`clearBit` (the mutating pair) drop; `withBit`/`withoutBit`
  stay.** Value semantics means the mutating forms would have to return the
  new value anyway, at which point they are the `with*` pair under a worse
  name.
- **`setBits` returns `Seq[int]` rather than being an iterator.** Per the
  "no *hidden* allocation" ruling, the cost is visible in the return type.
- `View[byte]` → `Seq[u8]` in `toBytes`/`fromBytes`, per `core.slice`.
- **`Whole` (the int-type union) is dropped.** Tuck has no type-union
  constraint verified in this pass; these are written against the widest
  concrete types, and a generic spelling waits on the same question as the
  rest of the numeric tower.
