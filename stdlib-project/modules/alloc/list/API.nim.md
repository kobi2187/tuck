# alloc.list — Nim API

**Purpose**
`Chain[T]` — a doubly-linked list. You almost certainly want `List[T]` (alloc.vec) or `Ring[T]` (alloc.deque) instead; this module exists for the two things a chain genuinely wins at: joining two big sequences in O(1), and inserting or removing at a position you already hold.

**Protocols implemented**
`Collection[T]`. Deliberately **not** `Gettable[int, T]` — see below.

## The API

```nim
type
  Chain*[T] = object    ## doubly-linked. One allocation per element — that is the cost you are paying.
  Spot*[T] = object     ## a place in a chain you can insert at, remove at, or step from

proc newChain*[T](memory = defaultMemory()): Chain[T]

proc addLast*[T](c: var Chain[T]; item: T): bool {.discardable.}
proc addFirst*[T](c: var Chain[T]; item: T): bool {.discardable.}
proc add*[T](c: var Chain[T]; item: T): bool {.discardable.}   ## Collection's verb; same as addLast
proc tryAddLast*[T](c: var Chain[T]; item: T): bool             ## false instead of raising OutOfMemory
proc takeFirst*[T](c: var Chain[T]): Option[T]
proc takeLast*[T](c: var Chain[T]): Option[T]
proc remove*[T](c: var Chain[T]; item: T): Option[T]           ## Collection's verb; O(n), as you'd expect
proc count*[T](c: Chain[T]): int
proc clear*[T](c: var Chain[T])
iterator list*[T](c: Chain[T]): T                              ## the sole Collection primitive

proc joinOnto*[T](c: var Chain[T]; other: var Chain[T])
  ## The headline: moves every element of `other` onto the end of `c` in O(1), touching no allocator.
  ## `other` is left empty. This is the one thing List[T] cannot do.

proc firstSpot*[T](c: var Chain[T]): Option[Spot[T]]
proc lastSpot*[T](c: var Chain[T]): Option[Spot[T]]
proc get*[T](s: Spot[T]): var T                                ## the element here
proc addBefore*[T](s: var Spot[T]; item: T)                    ## O(1)
proc addAfter*[T](s: var Spot[T]; item: T)                     ## O(1)
proc remove*[T](s: var Spot[T]): Option[T]                     ## O(1); the spot moves to the next element
proc next*[T](s: Spot[T]): Option[Spot[T]]
proc prev*[T](s: Spot[T]): Option[Spot[T]]
```

`isEmpty`, `first`, `contains`, `toSeq`, `each` arrive from `Collection`.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `LinkedList<T>` | `Chain[T]` | forced: `List[T]` is `alloc.vec`'s type now. "Chain" is a truer picture anyway — links you can unhook |
| `CursorMut<'a, T>` | `Spot[T]` | "cursor" sounds like a text editor or a database. A spot is a place you're holding |
| `cursor_front_mut()` | `firstSpot` | matches `first`/`last` used everywhere else, and returns `Option` because an empty chain has no spot |
| `insert_before` / `insert_after` | `addBefore` / `addAfter` | `add` is the vocabulary verb; the suffix says where |
| `remove_current` | `remove(spot)` | the spot *is* the current position — "current" was saying it twice |
| `move_next` / `move_prev` | `next` / `prev` | returning `Option[Spot]` instead of mutating in place makes "I fell off the end" impossible to miss |
| `append(other)` | `joinOnto(c, other)` | says the direction. `a.append(b)` never tells you which one survives |
| `current()` | `get(spot)` | the structural verb, with the spot as its own locator |

## In use — an external merge sort's merge step

No app in the 26-app validation set needs this module. That absence is the finding, not a gap. The shape that would justify it looks like this:

```nim
var merged = newChain[Run](memory = arena)
for run in sortedRuns:
  var r = run                       # each already-sorted run, built elsewhere
  merged.joinOnto(r)                # O(1) per run, no copying, no reallocation, at any size

var s = merged.firstSpot().get()    # splice a late-arriving record into place
while s.get() < record: s = s.next().get()
s.addBefore(record)                 # O(1) — the other reason to be here
```

If your code doesn't look like that, use `List[T]`: it will be faster, smaller, and easier to read.

## Vocabulary exceptions

- **There is deliberately no `get(chain, index)`.** `Chain` is a `Collection` but not `Gettable[int, T]`, because indexed access on a linked list is O(n) and the accidentally-quadratic loop it invites is the single most common reason people regret this type. The vocabulary is a promise about *shape*, and honoring it here would break a promise about *cost*. Iterate with `list`, or hold a `Spot`.
- **`joinOnto` is a domain verb.** No structural verb means "graft one collection onto another in constant time," and calling it `add` would hide that it empties its argument.
- **`Spot` returns `Option` from `next`/`prev` rather than going stale.** Nim has no borrow checker to stop you holding a `Spot` across a mutation; `Option` plus a generation counter checked in debug builds is the honest weaker version, documented as a convention exactly as PROTOCOLS describes for opaque handles.
