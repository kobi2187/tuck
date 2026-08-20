# core.hash — Nim API

## Purpose
Turning a value into a number so a map can find it again. Two algorithms — a fast one and an attack-resistant one — plus a sliding-window checksum for spotting which parts of a file changed.

## Protocols implemented
**None of the nine.** `hash` is a domain verb the vocabulary explicitly permits; a hasher is not a collection, a resource or a stream. It does obey the argument-order rule (subject first, options last).

## The API

```nim
type
  Mixer* = concept var m
    ## Something bytes go into and a number comes out of.
    write(m, View[byte]) is int
    digest(m) is uint64

  Hashable* = concept x
    ## How a type feeds its own bytes to whichever mixer it's given. Written once
    ## per type, works with every algorithm.
    hash(x, var Mixer)

  FastHash* = object    ## FNV-1a. Quick, and easy to construct collisions against
                        ## on purpose — only for keys you generated yourself.
  SafeHash* = object    ## SipHash-1-3, keyed. Use this for anything a stranger
                        ## can choose: nicknames, room names, request paths.

func fastHash*(): FastHash
func safeHash*(key: (uint64, uint64)): SafeHash

proc write*(m: var FastHash | var SafeHash, data: View[byte]): int
func digest*(m: FastHash | SafeHash): uint64

func hashOf*[T: Hashable](value: T, using: Mixer = fastHash()): uint64
  ## The one-liner: `hashOf(nickname, using = safeHash(serverKey))`.

type
  SlidingSum* = object
    ## An Adler-32-style checksum over a window that moves through a file. Cheap
    ## to update by one byte at either end. Deliberately not a `Mixer`: it has no
    ## final state, and a match is only ever a *candidate* — confirm it with a
    ## real hash before believing two blocks are identical.
    a, b: uint32
    windowLen: Count

func slidingSum*(over: View[byte] = View[byte]()): SlidingSum
  ## Seeding from a whole block costs one pass; after that every slide is free.
proc slideIn*(s: var SlidingSum, arriving: byte)
  ## The window grows by one byte at the far end.
proc slideOut*(s: var SlidingSum, leaving: byte)
  ## The window shrinks by one byte at the near end. You pass the byte that's
  ## leaving, because this type never stores the window itself.
func digest*(s: SlidingSum): uint32
  ## Valid after every single slide, not just at some end.
func windowLength*(s: SlidingSum): Count
```

**Which one do I use?** If a collision would only make a lookup slower, it belongs here. If a collision would let someone forge an identity, or if you're storing the number as a name for content, that's `std.crypto`, not this module — `FastHash` and `SafeHash` are both unsuitable for content addressing, and say so in their doc comments.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `FnvHasher` | `FastHash` | Nobody knows what FNV stands for, and knowing wouldn't help them choose. The name now answers the actual question: fast, or safe? |
| `SipHasher13` | `SafeHash` | Same reasoning; "13" was a tuning parameter leaking into a public name. The algorithm is still documented — it just isn't the label. |
| `Hasher` trait | `Mixer` | "Hasher" and "Hash" differ by two letters and mean different things — a guaranteed mix-up. `Mixer` names what it does to the bytes. |
| `finish()` | `digest()` | `finish` implies a one-shot terminal state, exactly the assumption `SlidingSum` breaks. |
| `hash_one(v)` | `hashOf(v, using = ...)` | The algorithm becomes a named option, not a type parameter to puzzle over. |
| `RollingChecksum` | `SlidingSum` | Says both what moves and what it computes, and pairs with `slideIn`/`slideOut`. |

## In use

```nim
# chat-server: nicknames come from strangers, so they get the safe hasher
let bucket = hashOf(nickname, using = safeHash(serverSecret)) mod rooms.count

# backup-sync: find which blocks of the new file match the old one, in one pass
var window = slidingSum(over = fresh.slice(0 ..< blockSize))
for i in blockSize ..< fresh.count:
  known.get(window.digest()).ifSome(candidate):
    if strongHash(fresh.slice(i - blockSize ..< i)) == candidate.strong:
      reuse(candidate)                       # confirmed, not assumed
  window.slideOut(fresh[i - blockSize])
  window.slideIn(fresh[i])
```

## Vocabulary exceptions
`slideIn` and `slideOut` are domain verbs where `add`/`remove` were superficially tempting. They're justified because the protocol's `add` returns "true if newly added" and `remove` returns `Option[V]` — a sliding window has neither notion, so borrowing those names would promise a contract this type cannot honour. `digest` and `hash` are permitted domain verbs; both take their subject first.
