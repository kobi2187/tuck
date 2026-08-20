# alloc.allocator — Nim API

**Purpose**
Says *where memory comes from*. One small value — `Memory` — is handed to anything that allocates, plus four ready-made strategies (arena, pool, heap, secure) that cover the cases real programs actually have.

**Protocols implemented**
None of the nine directly: `Memory` is the substrate the other nine modules stand on. `Arena` and `Pool` do speak the shared vocabulary where it fits (`clear`, `count`), so they read like everything else.

## The API

```nim
type
  OutOfMemory* = object of Failure   ## core.error's base failure type. The one failure this tier raises.

  Memory* = object                   ## a plain value you pass around: three procs and a state pointer
    state*: pointer
    takeProc*:   proc (s: pointer; bytes, align: int): pointer {.nimcall, raises: [].}
    giveProc*:   proc (s: pointer; p: pointer; bytes: int)     {.nimcall, raises: [].}
    resizeProc*: proc (s: pointer; p: pointer; old, want, align: int): pointer {.nimcall, raises: [].}

proc take*(m: Memory; bytes: int; align = 8): pointer
  ## Raises `OutOfMemory`. Never quietly borrows from another `Memory`.
proc tryTake*(m: Memory; bytes: int; align = 8): pointer
  ## Returns `nil` instead of raising — the real-time-safe door.
proc give*(m: Memory; p: pointer; bytes: int)
proc resize*(m: Memory; p: pointer; old, want: int; align = 8): pointer
  ## Grows/shrinks in place or raises. No hidden copy to a different allocator.

proc defaultMemory*(): Memory   ## the process default (see below)
proc useMemory*(m: Memory)      ## call once at startup; `std` does it for you on a hosted OS
proc nimHeap*(): Memory         ## Nim's own allocShared/dealloc, wrapped as a Memory

type
  Arena* = object        ## bump a pointer along a buffer; freeing is free, you clear the lot
  Mark* = distinct int
  Pool* = object         ## fixed block size, fixed block count. O(1) worst case, never grows, never blocks.
  Heap* = object         ## general purpose; debug builds track leaks, double frees, use-after-free
  SecureMemory* = object ## zeroes on `give`; mlock/VirtualLock-backed where the OS allows

proc newArena*(buffer: var openArray[byte]): Arena          ## no heap in sight — embedded's whole story
proc newArena*(chunk = 64 * 1024; memory = defaultMemory()): Arena
proc mark*(a: Arena): Mark
proc clear*(a: var Arena; back: Mark)   ## O(1) rewind to a checkpoint
proc clear*(a: var Arena)               ## O(1) free everything
proc newPool*(blockSize, blocks: int; buffer: var openArray[byte]): Pool
proc count*(p: Pool): int               ## blocks still free
proc newSecureMemory*(inside = defaultMemory()): SecureMemory
proc isLocked*(s: SecureMemory): bool   ## honest `false` where the OS won't pin pages

converter toMemory*(a: var Arena): Memory   ## and the same for Pool, Heap, SecureMemory,
                                            ## so `memory = arena` just works at any call site
proc memory*[T](x: T): Memory               ## every alloc type answers "who allocated you?"

type Secret*[T] = object  ## owns a T built in SecureMemory; `=destroy` always zeroes; `$` is redacted
proc newSecret*[T](value: sink T; memory: SecureMemory): Secret[T]
proc use*[T](s: var Secret[T]; body: proc (value: var T))
  ## The only way in. There is deliberately no `get` — nothing borrowed can escape the block.
```

## How this coexists with Nim's own memory management

Nim's `--mm:arc`/`--mm:orc` decides **when** memory is released; `Memory` decides **where it came from**. They never argue, because they answer different questions. Every alloc-tier type is a plain `object` holding its `Memory` in a field, with `=destroy`/`=sink`/`=copy` hooks that hand the bytes back to *that same* `Memory`. So you get Nim's ordinary scope-based cleanup — no `defer`, no manual frees — over any allocator you like.

The ergonomic balance:

- **Easy case:** `newList[int]()` uses `defaultMemory()`. On a hosted OS, `std` calls `useMemory(nimHeap())` at startup, so this is exactly as cheap and as invisible as a plain `seq`. A weekend coder never types the word "allocator".
- **Explicit case:** `newList[int](memory = pool)` — a **trailing named argument**, per PROTOCOLS' argument-order rule, instead of Rust's parallel `new`/`new_in` constructor pair. Half the API surface, and the explicit path is the same code with one more word.
- **Freestanding:** on `--os:standalone`, `defaultMemory()` is declared `{.error: "no default heap on this target — pass memory = yourArena".}`, so embedded-sensor-node's build *cannot compile* a call that would touch a heap that was never mapped. Not a runtime abort: a compile error.
- **Real-time:** mp3-player builds with `--mm:arc` (no cycle collector on the audio thread) and uses only the `try` verbs on the callback path — `tryTake`/`tryAdd` never raise, never block, never fall back.
- **Nim's own `seq`/`string`/`ref` still exist** and always use Nim's heap. Use them freely in `std`-tier code; use `List`/`Text` when placement matters.

Cost note: `Memory` is four words carried inline by each collection; `-d:singleMemory` collapses it to static dispatch against one global allocator (zero bytes per collection) for firmware that only ever has one arena.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Allocator` (trait) | `Memory` | "where memory comes from" is the thing; `memory = pool` reads like English at every call site |
| `alloc` / `dealloc` | `take` / `give` | two everyday words, obviously paired, and neither collides with a structural verb |
| `AllocError::OutOfMemory` | `OutOfMemory` | one word, raised, unmistakable — see the try-rule below |
| `ArenaAllocator` / `PoolAllocator` | `Arena` / `Pool` | the `-Allocator` suffix added nothing once the module is named `allocator` |
| `GeneralPurposeAllocator` | `Heap` | what everybody already calls it |
| `SecureAllocator` | `SecureMemory` | matches `Memory`; keeps `Secret[T]` obviously related |
| `reset` / `reset_to(mark)` | `clear` / `clear(back = mark)` | `clear` is already the vocabulary's "empty it" verb — no synonym needed |
| `set_default_allocator` | `useMemory` | shorter, and reads as an instruction rather than a setter |
| `new()` / `new_in(a)` pair | one ctor, `memory =` named arg | the fixed argument-order convention already covers this |

## In use — embedded-sensor-node

```nim
var arenaBytes {.align(8).}: array[8192, byte]     # the entire heap this firmware will ever have
let arena = newArena(arenaBytes)

var samples = newRing[int16](256, memory = arena)  # fixed ring, never allocates again
while true:
  let mark = arena.mark()                          # checkpoint before per-cycle scratch
  let raw = sensor.read(timeout = 10.ms)
  samples.addLast(raw.filtered())
  arena.clear(mark)                                # O(1) rewind — no per-object frees, no fragmentation
  sleep(SampleInterval)
```

And mp3-player's audio callback, where failure must be loud but never slow:

```nim
let pool = newPool(blockSize = 4096, blocks = 32, buffer = audioBytes)
let buf = pool.tryTake(4096)                       # nil, never a stall, never a raise
if buf.isNil: stats.underruns.inc                  # report it; do not reach for malloc
```

## Vocabulary exceptions

- **`take` / `give` / `resize` are domain verbs.** There is no structural verb for "hand me raw bytes" — `get`/`set` are locator-based reads and writes, and forcing them here would be actively misleading. They obey the argument-order rule (`m` first, size, then `align` as a trailing named argument).
- **`clear` is reused for arena reset.** Deliberately not a new word: rewinding an arena *is* emptying it, and `clear(a, back = mark)` reads as a narrower `clear`, not a different operation.
- **`Secret[T]` is deliberately not `Gettable`.** A secret you can `get` out is a design failure — PROTOCOLS' own `std.crypto` note makes the same point. `use(secret) do (v: var T)` is the whole interface.
