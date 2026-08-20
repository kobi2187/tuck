# std.random — Nim API

## Purpose
Dice, shuffles, jitter, and test data. Fast, seedable, reproducible — and deliberately unable to stand in for `std.crypto`'s secure randomness, because the two get confused in real programs and the consequence is silent.

## Protocols implemented
None of the nine — domain module. A generator is a source, not a container: nothing to `get` by key, nothing to `list` (the sequence is unbounded), nothing to `add`. Its verbs are its own.

## The API

```nim
type Dice* = object
  ## A seeded pseudo-random generator. Copyable — copy it to fork a reproducible
  ## sub-sequence. Deliberately shares NO type or proc with std.crypto.

proc newDice*(seed: uint64): Dice          ## same seed, same numbers, forever
proc newDice*(): Dice                       ## seeded from the OS, still not secure

proc roll*[T: SomeInteger](d: var Dice; range: HSlice[T, T]): T
  ## `d.roll(1..6)`. Uniform, no modulo bias.
proc roll*(d: var Dice): float              ## 0.0 ..< 1.0
proc chance*(d: var Dice; probability: float): bool
  ## `if d.chance(0.3): …` — reads as the question you were asking anyway.
proc pick*[T](d: var Dice; items: openArray[T]): Option[T]
  ## One item, uniformly. `none` for an empty collection — absence, per the rule.
proc pickWeighted*[T](d: var Dice; items: openArray[T]; weights: openArray[float]): Option[T]
proc shuffle*[T](d: var Dice; items: var openArray[T])
  ## In place. Fisher-Yates, unbiased.
proc sample*[T](d: var Dice; items: openArray[T]; count: int): List[T]
  ## `count` distinct items without replacement.
proc fill*(d: var Dice; bytes: var openArray[byte])
  ## Fast bytes for test fixtures. NOT for keys, nonces or tokens — see below.
```

There is no global `random()`. A `Dice` is always passed explicitly, which is what makes a failing test reproducible: log the seed, replay the run.

## The separation from `std.crypto`, enforced by the compiler

```nim
# std.crypto's randomBytes returns a Secret[T]; std.random's fill writes plain bytes.
# The types do not meet, so this does not compile:
let key = Key(newDice().fill(buf))     # Error: expected Secret[array[32, byte]]
```

`std.crypto.randomBytes` and `std.random.fill` share no type, no protocol, and no name. You cannot reach a `Key` from a `Dice`, and the mistake is caught at compile time rather than discovered in an audit. This is the Go `math/rand` vs `crypto/rand` split, made structural instead of conventional.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Rng` / `StdRng` / `SmallRng` | `Dice` | one type, and a word that already means "random, for play, not for security" |
| `rng.gen_range(1..6)` | `d.roll(1..6)` | what you say out loud when you do it |
| `rng.gen_bool(0.3)` | `d.chance(0.3)` | `gen_bool` names the return type; `chance` names the question |
| `choose` / `choose_weighted` | `pick` / `pickWeighted` | shorter, and `pick` returning `Option` follows the absence rule for an empty list |
| `choose_multiple` | `sample` | the statistics word, and it distinguishes "several, distinct" from repeated `pick` |
| `fill_bytes` | `fill` | the target is already in the argument; the suffix said nothing |
| `SeedableRng::from_entropy` | `newDice()` (no argument) | the no-argument overload *is* the entropy one; two names were one too many |

## In use

```nim
# cli-hangman: the whole module's job, in three lines
var dice = newDice()
let secret = dice.pick(wordlist).get()
if dice.chance(0.1): echo "(bonus round!)"

# sudoku-solver: a reproducible generator — log the seed, replay the exact puzzle
var dice = newDice(seed = 20260820)
dice.shuffle(cellOrder)

# std.testing's property runner uses the same type, so a failing case replays
```

## Vocabulary exceptions
`roll`, `chance`, `shuffle`, `sample` and `fill` are domain verbs. `pick` is a near-miss on the table's `find`: both return `Option`, but `find` takes a predicate and answers "is there one like this", while `pick` takes no predicate and answers "give me any one". Reusing `find` would have made the signature lie about what selects the result, so the two stay distinct — and `pick`'s `Option` return keeps it inside the absence rule regardless.
