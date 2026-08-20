# alloc.box — Nim API

**Purpose**
`Owned[T]` — put one value on the heap, with exactly one owner, in the allocator of your choosing. For values too big for the stack, for recursive types, and for anything you want living in an arena rather than Nim's heap.

**Protocols implemented**
None of the nine. `Owned[T]` holds a single value with no key, no iteration, and no lifecycle — forcing a protocol onto it would be ceremony without meaning. It is the smallest type in the tier and stays that way.

## The API

```nim
type Owned*[T] = object   ## one value, one owner, one Memory. Freed by =destroy when it goes out of scope.

proc own*[T](value: sink T; memory = defaultMemory()): Owned[T]
  ## Moves `value` onto the heap. Raises OutOfMemory.
proc tryOwn*[T](value: sink T; memory = defaultMemory()): Option[Owned[T]]
  ## For pool and arena code that must not unwind.

proc get*[T](o: Owned[T]): var T          ## the value. There is only one, so there is no key.
proc `[]`*[T](o: Owned[T]): var T         ## `o[]` — Nim's dereference, so Owned reads like a `ref`
proc release*[T](o: var Owned[T]): T      ## move the value back out and free the box
proc memory*[T](o: Owned[T]): Memory

proc `=copy`*[T](dst: var Owned[T]; src: Owned[T]) {.error: "Owned has one owner — use copyInto or share it with alloc.rc".}
proc `=sink`*[T](dst: var Owned[T]; src: Owned[T])
proc `=destroy`*[T](o: var Owned[T])      ## gives the bytes back to the Memory it came from

proc copyInto*[T](o: Owned[T]; memory = defaultMemory()): Owned[T]
  ## An explicit second allocation, because a heap copy should be visible where it happens.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Box<T>` | `Owned[T]` | "box" describes the container; "owned" describes the thing that actually matters — that there is one owner |
| `Box::new(v)` | `own(v, memory =)` | a verb, so the call site reads `let state = own(bigThing)`. `new` in Nim already means something to everyone |
| `into_inner()` | `release` | says the box is giving the value up, and pairs with `own` |
| `deref()` / `deref_mut()` | `get(o)` / `o[]` | the structural verb plus Nim's own deref operator; two Rust methods become one concept |
| `Box::clone` (via `T: Clone`) | `copyInto(o, memory =)` | `copy` is the vocabulary verb; the `Into` suffix makes the second allocation impossible to miss |
| `Box<dyn Trait>` | *(no equivalent — see below)* | Nim erases types with `ref object of RootObj`, not with a smart pointer |

## In use — chat-server's per-connection state

```nim
type ConnectionState = object
  inbox: Text          # partial line buffer
  nick: Text
  joined: List[RoomId]

proc handle(sock: TcpStream) =
  var state = own(ConnectionState(inbox: newText(capacity = 4096)))
  # too big to want on a task's stack; freed automatically when `handle` returns
  while sock.isOpen:
    state[].inbox.write(sock.read(1024))
    for line in state[].inbox.lines(): dispatch(state, line)
```

And mp3-player, where the same value lives in a pool instead:

```nim
let frame = tryOwn(DecodedFrame(), memory = audioPool)
if frame.isNone: stats.underruns.inc      # loud, bounded, never a malloc stall
```

## Vocabulary exceptions

- **`get(o)` has no locator.** `get(target, key)` is the general shape, but `Owned[T]` holds exactly one thing, so the key would always be the same constant. Dropping it is a narrowing, not a new verb — the same reasoning that lets `get(watcher)` work in `alloc.rc`.
- **`own` is a domain verb, not `add` or `set`.** It's a single unambiguous word for a single unambiguous act, which is precisely the case PROTOCOLS reserves domain verbs for.

## Nim-specific note: `Box<dyn Trait>` has no counterpart here

In the Rust design, `Box<T>` did two jobs: heap placement, and type erasure for dynamic dispatch (`Box<dyn Codec>`). Nim already has a blessed answer for the second — `ref object of RootObj` with `method`s, or a `concept` resolved at compile time — so `Owned[T]` is scoped to the first job only.

This is a real simplification, not a gap: archive-cli's runtime codec choice becomes `type Codec = ref object of RootObj` with `method compress(c: Codec, ...)`, and doc-convert-tester's heterogeneous collection becomes a plain `List[Codec]`. Nim's `ref` uses Nim's own heap, which is correct for both of those apps (neither is on a real-time path). Code that needs *both* type erasure and a custom allocator builds a small explicit vtable object, exactly as `alloc.allocator`'s own `Memory` type does — that pattern is written once, in the allocator, and copied rather than generalized, because two occurrences do not make a protocol.
