# core.num — Nim API

## Purpose
Arithmetic where you say what should happen on overflow instead of hoping, plus the two other things integers get used for: reading and writing binary formats, and standing in for a small set of flags.

## Protocols implemented
`Gettable`/`Settable`/`Collection` in miniature, on the bitset side: `hasBit` is `has`, `setBit`/`clearBit` are `set` with a bit position as the locator, and `setBits` is `list`. The arithmetic side is domain verbs.

## The API

```nim
type Whole* = int8|int16|int32|int64|uint8|uint16|uint32|uint64

# --- arithmetic, with the overflow behaviour in the name ---
func tryAdd*[T: Whole](a, b: T): Option[T]
func trySub*[T: Whole](a, b: T): Option[T]
func tryMul*[T: Whole](a, b: T): Option[T]
func tryDiv*[T: Whole](a, b: T): Option[T]
  ## Absent on overflow *and* on divide-by-zero — one shape for "no valid answer".

func addClamped*[T: Whole](a, b: T): T     ## pins at the type's min/max
func subClamped*[T: Whole](a, b: T): T
func mulClamped*[T: Whole](a, b: T): T

func addWrapped*[T: Whole](a, b: T): T     ## deliberate modular arithmetic
func mulWrapped*[T: Whole](a, b: T): T

# --- binary formats ---
type ByteOrder* = enum Big, Little
func toBytes*[T: Whole](value: T, order = Big): array[sizeOf(T), byte]
func fromBytes*[T: Whole](_: typedesc[T], bytes: View[byte], order = Big): T
  ## Raises if the view is the wrong length; `tryFromBytes` doesn't.
func tryFromBytes*[T: Whole](_: typedesc[T], bytes: View[byte], order = Big): Option[T]

# --- an integer used as a small set of flags ---
func hasBit*[T: Whole](x: T, at: Index): bool            ## the `has` verb
proc setBit*[T: Whole](x: var T, at: Index)              ## the `set` verb
proc clearBit*[T: Whole](x: var T, at: Index)
proc flipBit*[T: Whole](x: var T, at: Index)
func withBit*[T: Whole](x: T, at: Index): T              ## same, but returns a new value
func withoutBit*[T: Whole](x: T, at: Index): T

func countBits*[T: Whole](x: T): Count                   ## how many are set
func lowestSetBit*[T: Whole](x: T): Option[Index]
  ## Absent when nothing is set — instead of the old "returns the bit width"
  ## sentinel that everyone forgets to check.
func highestSetBit*[T: Whole](x: T): Option[Index]
func onlyBit*[T: Whole](x: T): Option[Index]
  ## Present only if exactly one bit is set. "Naked single", in one call.

iterator setBits*[T: Whole](x: T): Index
  ## Every set position, lowest first. Costs one step per set bit, not one per
  ## bit of the type — so a 64-bit word with three flags takes three steps.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `checked_add` | `tryAdd` | It already returned an Option; now it's spelled with the library's `try` prefix, so it matches `tryOpen`, `tryTo`, `tryLoad`. One rule instead of a fifth family name. |
| `saturating_add` | `addClamped` | "Saturating" is a signal-processing word. `Clamped` matches `core.cmp.clamped` and `core.simd.addClamped`. |
| `wrapping_add` | `addWrapped` | Verb first, behaviour second — so all three families sort together at a call site and read as "add, but ___". |
| `overflowing_add` | *(dropped)* | Its only real use was checked arithmetic, which `tryAdd` does better. Removes a fourth family nobody could keep straight. |
| `trailing_zeros` | `lowestSetBit` -> `Option` | The clearest win here. The old name describes the implementation, answers a different question than the one you're asking, and returns 32 when the answer is "none" — a sentinel waiting to become a bug. |
| `leading_zeros` | `highestSetBit` | Same reasoning, same fix. |
| `count_ones` | `countBits` | "Ones" was about the bit pattern; you're counting flags. |
| `is_bit_set(i)` | `hasBit(at = i)` | The protocol's `has` verb, with a bit position as the locator. |
| `set_bit` returning a value | `setBit` (mutating) + `withBit` (copying) | The protocol says `set` mutates. Both forms exist; `with` marks the copying pair. |
| `ones()` | `setBits` | Named for what you get: the positions that are set. |
| `to_be_bytes` and its three siblings | `toBytes(order =)` / `fromBytes(order =)` | Four names became two verbs plus a named option, exactly as the argument-order convention prescribes — and `Big`/`Little` beat `be`/`le`. |
| *(none)* | `onlyBit` | New. `countBits(x) == 1` then `lowestSetBit(x)` is two calls and a subtle ordering; you wanted one. |

## In use

```nim
# sudoku-solver: a cell's candidates are nine bits of a uint16
var candidates: uint16 = 0b1_1111_1111

candidates.clearBit(digit)                        # this digit is taken in the row
if candidates.countBits() == 0: return unsolvable

candidates.onlyBit().ifSome(d): place(row, col, d)   # naked single, one call
for d in candidates.setBits():                       # only the live digits
  if wouldSolve(row, col, d): return some(d)

# archive-cli: an untrusted header field that must not overflow into a huge read
let need = entry.compressed.tryMul(ratioGuess).orRaise("archive claims an absurd size")
let size = uint32.fromBytes(header.slice(8 .. 11), order = Little)
```

## Vocabulary exceptions
The `Clamped`/`Wrapped` suffixes are a domain vocabulary for overflow behaviour; the structural table has nothing to say about arithmetic. They are applied consistently across `core.num`, `core.simd` and `core.convert`, which is what makes them learnable once. `setBits` uses a specific name rather than the protocol's `list` because a plain integer would then have a `list` whose meaning depends on whether you meant it as a number or a bitset — the one place where reusing the structural verb would create ambiguity rather than remove it.
