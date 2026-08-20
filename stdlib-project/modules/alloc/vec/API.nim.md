# alloc.vec — Nim API

**Purpose**
A growable array of things, kept in one contiguous block — the collection you should reach for unless you have a reason not to. Plus `Grid[T]`, a fixed-shape 2D table over the same single allocation.

**Protocols implemented**
`Collection[T]` and `Gettable[int, T]` (by index), per PROTOCOLS' assignment table. `keepIf` and the index-based `set` give it `Settable[int, T]` for free.

## The API

```nim
type
  List*[T] = object   ## growable, contiguous, allocator-aware. Not Nim's `seq` — see below.
  Grid*[T] = object   ## rows x cols over one flat List[T]. A table you index, not a matrix you multiply.

proc newList*[T](memory = defaultMemory()): List[T]
proc newList*[T](capacity: int; memory = defaultMemory()): List[T]
  ## Reserve up front when you know the size. One allocation instead of a dozen regrows.

proc add*[T](list: var List[T]; item: T): bool {.discardable.}
  ## Appends. Raises `OutOfMemory` if the memory says no. Always returns true (Collection's shape).
proc tryAdd*[T](list: var List[T]; item: T): bool
  ## false instead of raising — for pool/arena code that must not unwind.
proc pop*[T](list: var List[T]): Option[T]                  ## none if empty; absence is not a failure
proc remove*[T](list: var List[T]; index: int): Option[T]   ## shifts the tail; none if out of range
proc removeFast*[T](list: var List[T]; index: int): Option[T]
  ## O(1): swaps the last element into the hole. Order is not preserved — that's the deal.
proc insert*[T](list: var List[T]; index: int; item: T)
proc get*[T](list: List[T]; index: int): Option[T]          ## never raises, even for index -3
proc set*[T](list: var List[T]; index: int; value: T)
proc `[]`*[T](list: List[T]; index: int): var T             ## the fast, checked, everyday accessor
proc count*[T](list: List[T]): int
proc clear*[T](list: var List[T])
proc keepIf*[T](list: var List[T]; pred: proc (item: T): bool)
  ## Single pass, in place, no allocation. Nim's own sequtils name.
proc truncate*[T](list: var List[T]; length: int)
proc shrinkToFit*[T](list: var List[T])
proc addAll*[T](list: var List[T]; items: openArray[T])     ## bulk append, one growth check
proc toOpenArray*[T](list: List[T]): openArray[T]           ## zero-copy hand-off to core.slice and core.iter
iterator list*[T](l: List[T]): T                            ## the sole Collection primitive
iterator pairs*[T](l: List[T]): (int, T)

proc newGrid*[T](rows, cols: int; fill: T; memory = defaultMemory()): Grid[T]
proc get*[T](g: Grid[T]; row, col: int): T
proc set*[T](g: var Grid[T]; row, col: int; value: T)
proc `[]`*[T](g: var Grid[T]; row, col: int): var T          ## g[i, j] — Nim's multi-arg index sugar
proc row*[T](g: Grid[T]; row: int): openArray[T]            ## one row as a contiguous slice, no copy
proc rows*[T](g: Grid[T]): int
proc cols*[T](g: Grid[T]): int
```

Everything derivable from `list` — `isEmpty`, `first`, `contains`, `toSeq`, `each` — comes from PROTOCOLS' `Collection` bundle and is deliberately **not** redeclared here.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Vec<T>` | `List[T]` | PROTOCOLS' assignment table. "Vec" is a mathematician's word; a weekend coder wants a list |
| `push` | `add` | the structural verb. `list.add(x)` is what someone guesses first, every time |
| `swap_remove` | `removeFast` | says what you get (speed) instead of how it works (a swap) |
| `retain(f)` | `keepIf(pred)` | Nim's own `sequtils.keepIf`; "retain" makes people guess wrong about which half survives |
| `extend_from_slice` | `addAll` | plural of `add`, and obviously the bulk version |
| `as_slice` / `as_mut_slice` | `toOpenArray` | Nim's native zero-copy view; two Rust methods collapse into one |
| `with_capacity(n)` / `with_capacity_in(n, a)` | `newList[T](capacity, memory =)` | one constructor with named args |
| `len` | `count` | one word for "how many", library-wide |
| `Grid.get_mut(r, c)` | `g[r, c]` | Nim indexes with multiple arguments natively; `var T` return covers mutation |

## In use — diff-patch's LCS table

```nim
var lcs = newGrid[int32](a.count + 1, b.count + 1, fill = 0)
for i in 1 .. a.count:
  for j in 1 .. b.count:
    lcs[i, j] = if a[i-1] == b[j-1]: lcs[i-1, j-1] + 1
                else: max(lcs[i-1, j], lcs[i, j-1])

var script = newList[EditOp](capacity = a.count + b.count)   # one allocation for the whole edit script
for op in backtrack(lcs, a, b): script.add(op)
script.keepIf(op => op.kind != Unchanged)                    # drop context in --check mode
```

One flat allocation for the table, `g[i, j]` at every call site instead of hand-rolled `i * cols + j`, and the backtrace walks `lcs.row(i)` as a plain contiguous slice.

## Vocabulary exceptions

- **`get` takes two locators on `Grid`.** `get(g, row, col)` widens the `get(target, key)` shape rather than inventing a `Point` type nobody asked for. The argument-order rule still holds: target, locators, then options.
- **`add` returns `bool` but is `{.discardable.}`.** `Collection` requires the `bool`; Nim's `discardable` pragma means no call site ever has to acknowledge it. For a list the answer is always `true` — the honest signal is the raise, not the return value.
- **`List[T]` is not Nim's `seq[T]`.** Named on purpose: `seq` always uses Nim's own heap, which is the right answer for `std`-tier code and the wrong answer for mp3-player's audio thread. `toOpenArray` bridges the two with no copy.
- **Fallible allocation is a raise, not a `Result`.** The Rust design's own Open Questions flagged `Result`-per-`push` as ceremony at every call site. PROTOCOLS' try-rule resolves it: `add` raises, `tryAdd` doesn't, and the presence of `try` tells you which without reading a word of documentation.
