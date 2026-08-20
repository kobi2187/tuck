# core.cmp — Nim API

## Purpose
The one way anything in this library gets compared. Sorting, searching, map keys and your own types all speak the same three words, and floating-point NaN can't quietly scramble a sort.

## Protocols implemented
**None of the nine.** Comparison is the cross-cutting *mechanism* Principle 4 names ("one comparison mechanism"), not a structural protocol — the concepts below sit alongside the nine rather than extending them, and no new protocol is proposed, per the rule that a protocol needs two demanding modules first.

## The API

```nim
type
  Order* = enum
    Before, Same, After
    ## What you'd get sorting `a` before/with/after `b`. Reads correctly for
    ## numbers, dates, names and versions alike.

  Equatable* = concept a, b
    a == b is bool
  Comparable* = concept a, b
    ## May be undefined for some pairs — floats with NaN are the reason this exists.
    tryCompare(a, b) is Option[Order]
  Sortable* = concept a, b
    ## Always defined. Only `Sortable` types may be sorted or binary-searched.
    compare(a, b) is Order

func compare*[T: Sortable](a, b: T): Order
func tryCompare*[T: Comparable](a, b: T): Option[Order]
  ## `none` means "these two genuinely can't be ordered", not "an error happened".

func flipped*(o: Order): Order
  ## Descending sorts: `compare(a, b).flipped()`
func breakTiesWith*(o: Order, next: Order): Order
  ## Multi-key sorting, left to right: primary key first, tiebreaker second.
template breakTiesWith*(o: Order, next: untyped): Order
  ## Same, but `next` is only evaluated if the first key tied.

func by*[T, K: Sortable](extract: proc (x: T): K {.nimcall.}): proc (a, b: T): Order
  ## Sort by a field without writing a comparison: `people.sort(by = by(age))`

func smaller*[T: Sortable](a, b: T): T
func larger*[T: Sortable](a, b: T): T
func clamped*[T: Sortable](x: T, low, high: T): T
  ## `x`, pulled inside the range. Pairs with core.num's `addClamped`.

func isSortable*(T: typedesc): bool {.compileTime.}
  ## `f64` answers false — which is the whole point of the split.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Ordering::{Less, Equal, Greater}` | `Order.{Before, Same, After}` | Sorting is the dominant use and "before/after" is what a sort actually means. `Equal` also read as "these are the same object", which it never meant. |
| `Eq` | `Equatable` | Says "can be compared for equality" rather than naming a mathematical structure. |
| `PartialOrd` | `Comparable` | "Partial" is a maths word. Pairing `tryCompare` with the library-wide `try` prefix already says "this can come back empty" — no new concept to teach. |
| `Ord` | `Sortable` | Names the thing you actually want it for. `sort` requires `Sortable`; a casual coder reads the error message and understands it. |
| `cmp(a, b)` | `compare(a, b)` | Unabbreviated. |
| `reverse()` | `flipped()` | `reverse` sounds like it mutates something. |
| `then` / `then_with` | `breakTiesWith` | This is the module's best rename: the Rust name explains nothing, the Nim one explains the whole multi-key sort idiom in place. Both forms share one name (proc + template overload). |
| `by_key(f)` | `by(f)` | Reads as the named argument it will be passed as: `sort(by = by(age))`. |
| `min`/`max` | `smaller`/`larger` | `min`/`max` stay reserved for numeric reductions in `core.num`; these two are about ordering *any* two values. |
| `clamp` | `clamped` | Nim convention: returns a new value, so past participle. |

## In use

```nim
# todo-cli: sort by priority, then due date, then title
tasks.sort(by = proc (a, b: Task): Order =
  compare(a.priority, b.priority)
    .breakTiesWith(compare(a.due, b.due))
    .breakTiesWith(compare(a.title, b.title)))

# math-toolkit-cli: floats aren't Sortable, so NaN has to be dealt with on purpose
let clean = cells.list().keep(proc (x: float64): bool = tryCompare(x, x).isSome)
```

## Vocabulary exceptions
`compare` is a domain verb, and `breakTiesWith`, `flipped`, `smaller`, `larger` and `clamped` are ordering-domain words with no structural equivalent. `tryCompare` uses the `try` prefix for "may legitimately have no answer" rather than for "opts out of raising" — a slight stretch of the rule, kept because the caller-visible consequence is identical (you get an `Option` and must decide), and inventing a fourth failure-mode marker would cost more than it clarifies.
