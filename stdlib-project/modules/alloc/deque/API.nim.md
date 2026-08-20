# alloc.deque — Nim API

**Purpose**
`Ring[T]` — a queue you can add to and take from at either end, cheaply. The right answer for work queues, sliding windows, and fixed-size histories, all of which `List[T]` handles badly at the front.

**Protocols implemented**
`Collection[T]` and `Messenger[T]` (add/take read as send/receive), per PROTOCOLS' assignment table.

## The API

```nim
type
  Ring*[T] = object       ## one contiguous buffer with wraparound. Not a chain of chunks.
  WhenFull* = enum
    grow,                 ## default: allocate a bigger buffer
    reject,               ## refuse the new item — "this must never silently lose data"
    dropOldest            ## evict the front to make room — "this is a log"

proc newRing*[T](memory = defaultMemory()): Ring[T]
proc newRing*[T](capacity: int; whenFull = grow; memory = defaultMemory()): Ring[T]
  ## With `whenFull = dropOldest` or `reject` this never calls the allocator again after construction.
  ## That's the embedded/real-time mode, and it's a constructor argument so the intent lives in one place.

proc addLast*[T](r: var Ring[T]; item: T): bool {.discardable.}
proc addFirst*[T](r: var Ring[T]; item: T): bool {.discardable.}
proc add*[T](r: var Ring[T]; item: T): bool {.discardable.}   ## Collection's verb; same as addLast
proc tryAddLast*[T](r: var Ring[T]; item: T): bool            ## false instead of raising OutOfMemory
proc addLastEvicting*[T](r: var Ring[T]; item: T): Option[T]
  ## dropOldest mode, but hands you what fell off the front so you can flush it somewhere first.
proc takeFirst*[T](r: var Ring[T]): Option[T]                 ## none if empty
proc takeLast*[T](r: var Ring[T]): Option[T]
proc first*[T](r: Ring[T]): Option[T]                         ## peek, don't take
proc last*[T](r: Ring[T]): Option[T]
proc get*[T](r: Ring[T]; index: int): Option[T]               ## 0 is the front, wraparound hidden
proc remove*[T](r: var Ring[T]; item: T): Option[T]           ## Collection's verb; O(n)
proc count*[T](r: Ring[T]): int
proc capacity*[T](r: Ring[T]): int
proc isFull*[T](r: Ring[T]): bool
proc clear*[T](r: var Ring[T])
iterator list*[T](r: Ring[T]): T                              ## front to back

# Messenger — the same ring, spoken in the message vocabulary
proc send*[T](r: var Ring[T]; msg: T)                         ## addLast
proc receive*[T](r: var Ring[T]; timeout = 0.ms): Option[T]   ## takeFirst
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `VecDeque<T>` | `Ring[T]` | PROTOCOLS' table. "Deque" is unpronounceable and unguessable; a ring is a picture you already have |
| `push_back` / `push_front` | `addLast` / `addFirst` | Nim's own `deques` names, and `add` is already the vocabulary verb |
| `pop_front` / `pop_back` | `takeFirst` / `takeLast` | "take" says you get the item back; `pop_front` makes people wonder which end "front" is |
| `front()` / `back()` | `first` / `last` | matches `SortedSet.first`/`last` and the `Collection` bundle's `first` |
| `OverflowPolicy::{Reject, OverwriteOldest}` | `WhenFull.{grow, reject, dropOldest}` | reads at the call site as a sentence: `newRing(256, whenFull = dropOldest)` |
| `with_fixed_capacity_in(n, p, a)` | `newRing(capacity, whenFull =, memory =)` | one constructor; fixed-capacity is a named argument, not a second name to learn |
| *(open question)* | `addLastEvicting` | resolves the Rust design's flagged gap: you get the evicted element back instead of losing it |

## In use — embedded-sensor-node

```nim
var ringBytes {.align(8).}: array[512, byte]
let arena = newArena(ringBytes)
var samples = newRing[Sample](256, whenFull = dropOldest, memory = arena)
  # fixed forever: after this line the allocator is never touched again

proc onSampleReady(s: Sample) =
  let evicted = samples.addLastEvicting(s)
  if evicted.isSome: flash.append(evicted.get())   # wear-conscious flush, nothing silently lost
```

And web-downloader's bounded work queue, which needs none of that:

```nim
var queue = newRing[DownloadTask]()
for ep in newEpisodes: queue.send(ep)
while let task = queue.receive():                  # Messenger, in-process, returns immediately
  workers.hand(task)
```

## Vocabulary exceptions

- **`receive(r, timeout)` ignores the timeout.** `Ring` is a plain in-process buffer with nothing to wait *for* — it returns `Option` immediately. The parameter exists so `Ring` really satisfies `Messenger` and so a `Ring` can be swapped for a `sys.sync.Channel` in test code without touching the call site. A non-zero timeout is documented as a no-op rather than quietly sleeping.
- **`addLastEvicting` is a compound verb.** Justified by the concrete gap it closes; `addLast` on its own cannot report an eviction, and returning `Option[T]` from `addLast` would make the common growing case pay for a case it can't have.
- **This is the single-threaded queue.** mp3-player's UI-to-audio handoff is `sys.sync`'s lock-free SPSC ring, not this one. Same picture, different tier, and conflating them would be a real bug.
