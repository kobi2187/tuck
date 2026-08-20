# alloc.rc — Nim API

**Purpose**
`Shared[T]` — one value with several genuine owners, kept alive until the last one lets go. `Watcher[T]` is a look-but-don't-hold handle that breaks the cycles `Shared` would otherwise leak.

**Protocols implemented**
None of the nine. Shared ownership is about lifetime, not about keys, iteration, or lifecycle. `Watcher` does use the structural `get` verb, returning `Option` for exactly the reason the vocabulary says it should: the value may simply not be there any more.

## The API

```nim
type
  Shared*[T] = object    ## a counted owner. Single-threaded: the count is not atomic.
  Watcher*[T] = object   ## watches without owning. Never keeps the value alive.

proc share*[T](value: sink T; memory = defaultMemory()): Shared[T]
  ## Moves the value to the heap with a count of 1. Raises OutOfMemory.
proc tryShare*[T](value: sink T; memory = defaultMemory()): Option[Shared[T]]

proc get*[T](s: Shared[T]): T           ## read the value; every owner sees the same one
proc `[]`*[T](s: Shared[T]): T          ## `s[]`, so Shared reads like a Nim `ref`
proc getOwn*[T](s: var Shared[T]): Option[var T]
  ## A mutable view, but only while you are the sole owner. `none` means someone else is looking.
proc watch*[T](s: Shared[T]): Watcher[T]
proc get*[T](w: Watcher[T]): Option[Shared[T]]
  ## Turn a watch back into an owner. `none` if the value is already gone — which is normal, not an error.
proc owners*[T](s: Shared[T]): int      ## how many Shared handles exist
proc watchers*[T](s: Shared[T]): int
proc isSame*[T](a, b: Shared[T]): bool  ## same value in memory, not merely equal values
proc memory*[T](s: Shared[T]): Memory

proc `=copy`*[T](dst: var Shared[T]; src: Shared[T])
  ## Bumps the count. Cheap, never allocates, never raises — unlike `share`.
proc `=destroy`*[T](s: var Shared[T])
  ## Drops the count; frees through the original Memory when it hits zero.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Rc<T>` | `Shared[T]` | "Rc" is an implementation detail spelled as a name. "Shared" is the property you were reaching for |
| `Weak<T>` | `Watcher[T]` | a weak reference *watches*; "weak" tells you nothing about what it does or when to use it |
| `Rc::new(v)` | `share(v, memory =)` | a verb at the call site: `let meta = share(showInfo)` |
| `downgrade()` | `watch(s)` | pairs with `Watcher`, and "downgrade" sounds like a punishment |
| `upgrade()` | `get(w)` | the structural verb, returning `Option` — exactly the vocabulary's absence rule, no new word needed |
| `strong_count` / `weak_count` | `owners` / `watchers` | count the people, not the pointer category |
| `get_mut()` | `getOwn` | says the precondition ("only if you own it alone") in the name instead of the docs |
| `ptr_eq(a, b)` | `isSame(a, b)` | identity versus equality, in a word a beginner already distinguishes |

## In use — podcast-subscriber

```nim
let show = share(ShowMetadata(title: feed.title, artwork: art))
for entry in feed.entries:
  library.add(Episode(guid: entry.guid, show: show))   # one copy of the metadata, many episodes
# Rename the show once and every episode sees it. `show` is freed when the last episode goes.
```

And chat-server's rooms, which must not resurrect a disconnected client:

```nim
type Room = object
  members: List[Watcher[Client]]      # watchers, not owners

proc broadcast(room: var Room; msg: Text) =
  room.members.keepIf do (w: Watcher[Client]) -> bool:
    let c = w.get()
    if c.isNone: return false         # client is gone; prune, don't resurrect
    c.get()[].send(msg)
    true
```

## Vocabulary exceptions

- **`get(shared)` and `get(watcher)` take no locator.** Same narrowing as `alloc.box`: there is one value, so a key would be a constant. `get(watcher): Option[Shared[T]]` is a textbook use of the absence rule — the value may have been freed, and that is an ordinary outcome, not a failure to raise about.
- **`share` and `watch` are domain verbs.** Single unambiguous words for ownership acts that have no structural analogue.
- **`getOwn` is a compound.** It is `get`, restricted. Naming it plain `get` would give one word two failure meanings on one type, which is worse than one extra syllable.

## Nim-specific notes

- **`=copy` does the counting.** Rust needed an explicit `Rc::clone(&x)` to keep the cost visible. Nim's copy hook makes `let b = a` bump the count automatically, which is friendlier and matches how `ref` already behaves. The cost stays visible where it matters — in the type's name.
- **There is still no `Arc` here.** Atomic counting only means something once OS threads exist, so a thread-safe `Shared` belongs at `sys`, built on `core.atomic`. Migrating is a one-word type change, and the method names are identical on purpose.
- **`Shared[T]` and Nim's `ref T` are different tools.** `ref` is counted by ARC on Nim's own heap and is the right choice in `std`-tier code. `Shared[T]` is what you use when the value must live in an arena, a pool, or secure memory — the placement the `ref` cannot give you.
- **Cycles are still yours to break.** `Watcher` is the whole answer at this tier; there is no tracing collector under `alloc`. Building with `--mm:orc` collects cycles among Nim's own `ref`s, but never among `Shared[T]` values in a custom `Memory` — stated plainly so nobody assumes otherwise.
