# sys.sync — Nim API

## Purpose
Sharing state between threads without getting it wrong: a lock that owns what it protects, channels for handing work along, and a lock-free handoff for the one thread that must never, ever block.

## Protocols implemented
`Channel[T]` and `Handoff[T]` are `Messenger[T]`, per PROTOCOLS' assignment table. `Barrier` and `Gate` are `Waitable`. `Guarded[T]` is none of the nine on purpose — see the exceptions.

## The API

```nim
type Guarded*[T] = object
  ## A lock that owns its value. There is no way to touch the value without holding
  ## the lock, so "forgot to lock" is not a bug you can write.

proc newGuarded*[T](value: sink T): Guarded[T]           ## one thread at a time
proc newReadShared*[T](value: sink T): Guarded[T]
  ## Same type, many concurrent readers. The constructor picks the implementation, so a
  ## caller never has to decide between two type names — only how it will be used.

template use*[T](g: var Guarded[T]; body: untyped)
  ## Exclusive. `g.use do (v: var T): ...`. Released on the way out even if `body` raises,
  ## and the exception simply propagates — there is no poison flag to deal with afterwards.
template read*[T](g: Guarded[T]; body: untyped)
  ## Shared where the value is read-shared, exclusive where it isn't. Always correct.
template tryUse*[T](g: var Guarded[T]; body: untyped): bool
  ## Runs `body` only if the lock was free. Never blocks.

type
  Channel*[T] = object     ## Messenger. Many senders, many receivers, one queue
const Unbounded* = -1
proc newChannel*[T](capacity: int): Channel[T]
  ## `capacity` has no default on purpose: an unbounded queue silently growing behind a slow
  ## consumer is a real outage, so you write `Unbounded` and it shows up in review.
proc send*[T](c: var Channel[T]; msg: sink T)            ## blocks when full — that is backpressure
proc trySend*[T](c: var Channel[T]; msg: sink T): bool   ## false instead of blocking
proc receive*[T](c: var Channel[T]; timeout = Forever): Option[T]
  ## Absent on timeout or once the channel is closed and drained.
proc close*[T](c: var Channel[T])                        ## receivers see the end and stop looping
proc count*[T](c: Channel[T]): int

type
  Handoff*[T] = object          ## lock-free, one producer, one consumer, fixed size
  Producer*[T] = object         ## Messenger, but `trySend` only
  Consumer*[T] = object
proc newHandoff*[T](capacity: int; memory = defaultMemory()): (Producer[T], Consumer[T])
  ## Allocates once, here, and never again. `trySend`/`tryReceive` never block, never
  ## allocate, never raise, and never take a lock — the only shape a real-time audio
  ## callback can call at all.
proc trySend*[T](p: var Producer[T]; msg: sink T): bool
proc tryReceive*[T](c: var Consumer[T]): Option[T]

type
  Gate* = object                ## Waitable: one-shot "everybody may go now"
  Barrier* = object             ## Waitable: rendezvous for a fixed number of threads
proc wait*(g: Gate; timeout = Forever): bool
proc openGate*(g: var Gate)
proc newBarrier*(threads: int): Barrier
proc wait*(b: var Barrier; timeout = Forever): bool
template once*(o: var Once; body: untyped)   ## runs `body` exactly once, whoever gets there first
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Mutex<T>` + `RwLock<T>` | one `Guarded[T]`, two constructors | a casual coder shouldn't have to pick a lock flavour to store a value; usage picks it |
| `lock()` → `MutexGuard<T>` | `use do (v: var T)` | no guard object, no `Deref`, and the same scoped shape `Secret[T]` already uses |
| `read()` / `write()` on `RwLock` | `read` / `use` | `write` is `Streamable`'s word and could not be reused here |
| `PoisonError` | *(gone)* | Nim unwinds and the `use` template releases in `finally`. Rust's own experience says poisoning annoyed more than it protected |
| `channel()` / `sync_channel(n)` | `newChannel[T](capacity)` | one constructor; `Unbounded` is a word you have to type |
| `Sender` / `Receiver` | `Channel[T]` shared by both ends | Nim's `sink`/`var` parameters carry the ownership Rust needed two types for |
| `recv` / `try_recv` / `recv_timeout` | `receive(c, timeout =)` | three names collapse; absence is `Option`, per the rule |
| `SpscRing` + `split()` | `newHandoff[T]` → `(Producer, Consumer)` | says what it's for; "SPSC ring buffer" is an implementation detail |
| `Barrier` / `Once` | kept | already the plain-English words |

## In use

```nim
# mp3-player: UI thread to audio callback, no lock, no allocation, no raise
let (toAudio, fromUi) = newHandoff[Chunk](capacity = 64, memory = audioPool)

proc audioCallback(out: var openArray[int16]) {.thread, gcsafe.} =
  fromUi.tryReceive().ifSome(chunk): chunk.mixInto(out)
  # nothing here can block: a missed chunk is one silent buffer, not a stall

# chat-server: the room registry, read-heavy and write-rare
var rooms = newReadShared(newTable[Text, List[Client]]())
rooms.read do (r: Table[Text, List[Client]]):
  for c in r.get(room).get().list(): c.writeAll(line)     # many broadcasters at once
rooms.use do (r: var Table[Text, List[Client]]):
  r.getOrSet(room, newList[Client]()).add(client)          # exclusive, and brief
```

## Vocabulary exceptions
- **`Guarded[T]` is deliberately not `Gettable`.** A value you can `get` out of a lock is a value you can use after releasing it — the same reasoning that keeps `alloc.allocator`'s `Secret[T]` out of `Gettable`, and the same `use`-block answer.
- **`use`, `read` and `once` are templates, not procs taking a closure.** Nim closures allocate and are not `gcsafe` across threads; templates inline the body, so the audio path stays allocation-free and the compiler still checks GC-safety.
- **`trySend`/`tryReceive` on `Handoff` mean "and never blocks" as well as "and never raises."** The `try` prefix carries slightly more weight here than elsewhere, which the doc comment states outright rather than leaving to be discovered.
- **Sharded locking is a pattern, not a type.** `newList[Guarded[Table[K,V]]]()` plus `hash(key) mod shards` already expresses it; a `ShardedTable` belongs in `alloc.map` if anywhere.
