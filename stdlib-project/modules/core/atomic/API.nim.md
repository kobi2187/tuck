# core.atomic — Nim API

## Purpose
Counters, flags and pointers that several threads (or a main loop and an interrupt handler) can touch at once without tearing. This is the bottom of the concurrency stack — `sys.sync`'s locks and channels are built out of these.

## Protocols implemented
`Adjustable[T]` — `adjust(target, delta)` is exactly `fetch_add` and gets the protocol's name. The `read`/`write` verbs are used in their table sense as well.

## The API

```nim
type
  MemoryOrder* = enum
    Loose            ## no ordering promises; fine for a plain statistics counter
    Acquire          ## reads after this one see everything the releaser published
    Release          ## publishes everything written before this one
    AcquireRelease
    Strict           ## one global order everyone agrees on — the safe default

  Atomic*[T] = object
    ## T is an integer, bool, or pointer that fits a native word.
    value: T

func atomic*[T](initial: T): Atomic[T]

proc read*[T](a: Atomic[T], order = Strict): T
proc write*[T](a: var Atomic[T], value: T, order = Strict)
proc swap*[T](a: var Atomic[T], value: T, order = Strict): T
  ## Puts the new value in, hands back the old one. Same meaning as core.mem's swapIn.

proc adjust*[T](a: var Atomic[T], delta: T, order = Strict): T
  ## Add `delta` (negative to subtract) and hand back the value *as it was before*.
proc adjustBits*[T](a: var Atomic[T], mask: T, how: BitOp, order = Strict): T
  ## `how` is `KeepOnly` (and), `AlsoSet` (or), or `Flip` (xor).

proc swapIfEqual*[T](a: var Atomic[T], expected: var T, wanted: T,
                     order = Strict): bool
  ## True if `a` held `expected` and now holds `wanted`. On false, `expected` is
  ## updated to what was actually there, ready for another go round the loop.
proc trySwapIfEqual*[T](a: var Atomic[T], expected: var T, wanted: T,
                        order = Strict): bool
  ## Cheaper, and allowed to fail for no reason at all — only correct inside a
  ## retry loop, which is where you want it.

proc barrier*(order = Strict)
  ## Order memory accesses either side of this point, with no value involved.
proc compilerBarrier*(order = Strict)
  ## Order them for the compiler only, no CPU instruction — what a single-core
  ## interrupt handler needs, and all it should pay for.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Ordering::{Relaxed, SeqCst}` | `MemoryOrder.{Loose, Strict}` | `Ordering` collided with `core.cmp`'s comparison result — a real ambiguity, not a style point. `SeqCst` is an abbreviation of a phrase most people can't expand; `Strict` says what it costs you. |
| `load` / `store` | `read` / `write` | The protocol's verbs. Nobody has to learn that "load" and "get" are the same idea. |
| `fetch_add(d)` | `adjust(d)` | Straight onto the `Adjustable` protocol. `fetch_sub` disappears: pass a negative delta. |
| `fetch_and`/`fetch_or`/`fetch_xor` | `adjustBits(mask, how)` | Three near-identical procs became one with a named choice, reading as "adjust, but bitwise". |
| `compare_exchange` | `swapIfEqual` | Says the whole contract in the name; the old one described a CPU instruction. |
| `compare_exchange_weak` | `trySwapIfEqual` | The `try` prefix already means "can come back empty without anything being wrong" — precisely what a spurious CAS failure is. |
| `Result<u32,u32>` return | `bool` + `var expected` | The old shape hid the current value in an error arm; the retry loop wants it in the variable it already has. |
| `fence` / `compiler_fence` | `barrier` / `compilerBarrier` | "Barrier" is the word more people already know from threading. |
| *(no default order)* | `order = Strict` | Deliberate change: the safe choice is the default, and it's a *named* argument, so a deliberate `Loose` is visible at the call site. Getting it wrong now costs speed, not correctness. |

## In use

```nim
# chat-server: connection accounting, no mutex needed
var liveConnections = atomic(0'i32)
discard liveConnections.adjust(1)                       # on accept
discard liveConnections.adjust(-1, order = Loose)       # on close; exactness can lag
echo "live: ", liveConnections.read(order = Loose)

# mp3-player: hand the freshly-decoded buffer to the audio thread, wait-free
var expected = published.read(order = Acquire)
while not published.trySwapIfEqual(expected, filled, order = Release):
  discard                                               # expected already refreshed
```

## Vocabulary exceptions
`adjust` returns the previous value; the table says `adjust` returns nothing. Deviating is justified because an atomic read-modify-write that discards the old value throws away the only thing that makes it atomic — every real caller (reference counts, ticket locks, sequence numbers) needs it. Nim lets callers `discard` it, so the plain "just bump it" call still reads exactly like the protocol's. `barrier` and `swapIfEqual` are domain verbs with no structural analogue.
