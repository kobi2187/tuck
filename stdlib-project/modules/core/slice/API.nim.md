# core.slice — Nim API

## Purpose
A borrowed window onto a run of memory — pointer plus length, always travelling together — plus the operations that work on it no matter who owns the storage: a stack array, a mapped file, or a block of hardware registers.

## Protocols implemented
`Gettable[Index, T]` and the read-only half of `Collection[T]` (`list`, `count`). Not the full `Collection`: a view has no `add`/`remove` because it never owns or resizes its storage. That gap is deliberate and named rather than faked with raising stubs.

## The API

```nim
type
  View*[T] = object
    ## A borrowed (start, length) window. Copyable, never owning, never resizing.
    start: ptr T
    length: Index

func view*[T](items: openArray[T]): View[T]
  ## The bridge from any Nim `openArray` — array, another view, an alloc.vec buffer.
func toOpenArray*[T](v: View[T]): openArray[T]
  ## The bridge back, so `View` composes with every ordinary Nim proc.

func count*[T](v: View[T]): Count
func isEmpty*[T](v: View[T]): bool
func get*[T](v: View[T], i: Index): Option[T]      ## absent when out of range — never raises
func `[]`*[T](v: View[T], i: Index): T             ## raises `Failure` on a bad index
func first*[T](v: View[T]): Option[T]
func last*[T](v: View[T]): Option[T]

func slice*[T](v: View[T], span: HSlice[Index, Index]): View[T]
  ## `line.slice(4 .. 9)` — a narrower window, no copy. Raises on a bad span.
func splitAt*[T](v: View[T], at: Index): (View[T], View[T])

iterator list*[T](v: View[T]): T                   ## the Collection primitive
iterator numbered*[T](v: View[T]): (Index, T)
iterator chunks*[T](v: View[T], size: Count): View[T]
  ## Non-overlapping windows; the last one may be shorter.
iterator windows*[T](v: View[T], size: Count): View[T]
  ## Overlapping windows — moving averages, diff hunk context.

func find*[T](v: View[T], test: proc (x: T): bool {.nimcall.}): Option[Index]
func findSorted*[T: Sortable](v: View[T], wanted: T): Option[Index]
  ## Binary search. Absent means "not in there", not "error".

proc sort*[T](v: var View[T], by: proc (a, b: T): Order {.nimcall.} = compare)
proc copyFrom*[T](v: var View[T], source: View[T])  ## raises if the lengths differ
func rawBytes*[T](v: View[T]): View[byte]
  ## The one, explicit, greppable way to look at typed memory as bytes.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Slice<'a, T>` | `View[T]` | `Slice` collides with Nim's `a..b` range type, and "view" says *borrowed* without a lifetime lecture. |
| `len` | `count` | The protocol verb. One word for "how many", everywhere. |
| `index(i)` (panics) | `` `[]`(i) `` | Nim already has bracket syntax; a distinct name for it would be noise. `get` stays the checked one. |
| `split_first` | `first` + `splitAt` | Two obvious words instead of one compound; `split_first` was only ever used to peel one element. |
| `binary_search -> Result<usize, usize>` | `findSorted -> Option[Index]` | The Rust version smuggled an insertion point into the error arm. Absence is `none`; insertion points belong in `alloc.vec`. |
| `contains` | *(inherited)* | Comes free from `list` per PROTOCOLS' derived-bundle rule — not redefined here. |
| `sort_by(cmp)` | `sort(v, by = compare)` | Options as trailing named args, and the common case needs no argument at all. |
| `as_bytes` | `rawBytes` | Keeps the "this is reinterpretation, look twice" signal that `as_` lost. |

## In use

```nim
# log-grep: scan an mmap'd region with no copies
let region = view(mapped)                        # ptr + len, nothing allocated
for line in region.splitOn('\n'.byte):
  if line.count > 0 and line[0] != '#'.byte:
    report(line)

# embedded-sensor-node: moving average over the sample ring, allocation-free
for w in samples.view().windows(4):
  push(w.list().reduce(0'u32, `+`) div 4)
```

## Vocabulary exceptions
`slice`, `splitAt`, `chunks`, and `windows` are domain verbs — the table has no word for "narrow this window". They obey the argument-order rule (target, then locator, then options) and each is a single unambiguous word, which is the standard PROTOCOLS sets for domain verbs.
