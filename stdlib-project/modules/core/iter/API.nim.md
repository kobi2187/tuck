# core.iter — Nim API

## Purpose
One way to walk a sequence of things, and a small set of adapters that chain onto it left to right. Everything iterable in the library — views, text, bitsets, later maps — implements the single primitive `list`, and gets the rest of this module for free.

## Protocols implemented
This module *is* the machinery behind `Collection[T]`: it defines `Listable[T]`, the one-proc concept a type satisfies by providing `list`, and it supplies the derived bundle (`count`, `first`, `contains`, `each`) that PROTOCOLS says nobody should hand-roll.

## The API

```nim
type
  Listable*[T] = concept c
    ## Implement this one iterator and every adapter below applies to your type.
    for item in c.list(): item is T

# Adapters — lazy, inlined, zero heap. See "Nim note" below for why these are
# `iterator`s over `iterable[T]` and not procs returning objects.
iterator map*[T, U](source: iterable[T], transform: proc (x: T): U {.nimcall.}): U
iterator keep*[T](source: iterable[T], test: proc (x: T): bool {.nimcall.}): T
iterator drop*[T](source: iterable[T], test: proc (x: T): bool {.nimcall.}): T
  ## The other half of `keep` — spelling `keep(not test)` by hand is the ceremony this removes.
iterator first*[T](source: iterable[T], n: Count): T        ## at most the first n
iterator skip*[T](source: iterable[T], n: Count): T
iterator numbered*[T](source: iterable[T]): (Index, T)
iterator zip*[T, U](source: iterable[T], other: iterable[U]): (T, U)
iterator followedBy*[T](source, other: iterable[T]): T
iterator splitOn*[T](v: View[T], separator: T): View[T]
  ## Line/record splitting over a borrowed buffer — the mmap-scanning workhorse.

# Terminals — these consume the sequence.
func reduce*[T, A](source: iterable[T], start: A,
                   combine: proc (acc: A, x: T): A {.nimcall.}): A
  ## The one universal reducer; `count`, `any`, `total` are all this underneath.
func tryReduce*[T, A](source: iterable[T], start: A,
                      combine: proc (acc: A, x: T): Option[A] {.nimcall.}): Option[A]
  ## Stops at the first `none`. Parse-then-total over untrusted input, without a hand-rolled loop.
func count*[T](source: iterable[T]): Count
func find*[T](source: iterable[T], test: proc (x: T): bool {.nimcall.}): Option[T]
func any*[T](source: iterable[T], test: proc (x: T): bool {.nimcall.}): bool
func all*[T](source: iterable[T], test: proc (x: T): bool {.nimcall.}): bool
proc each*[T](source: iterable[T], action: proc (x: T) {.nimcall.})
```

**Nim note.** Nim closure iterators allocate an environment, which the core tier forbids. So adapters are *inline* iterators taking Nim 2's `iterable[T]`: they fuse into the surrounding `for` loop at compile time, producing the same pointer-walking machine code Rust's adapter structs do, with no heap and no vtable. The cost is that an adapter chain can't be stored in a variable or returned from a proc — build it at the `for` loop. Under `--mm:none` / `--mm:arc` this is the only shape that works at all.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `filter` | `keep` | Says which side you get back. "Filter" is ambiguous in English — a coffee filter keeps the grounds. |
| *(none)* | `drop` | Added as `keep`'s partner so nobody writes an inverted predicate. |
| `fold(init, f)` | `reduce(start, combine)` | "Fold" is functional-programming jargon; the parameter names now explain the shape. |
| `try_fold` | `tryReduce` | The open question in the Rust file, resolved: the `try` prefix already means "returns instead of raising", so the name was free. |
| `enumerate` | `numbered` | Guessable without knowing Python. |
| `chain(other)` | `followedBy(other)` | Reads as English at the call site: `head.followedBy(tail)`. |
| `take(n)` | `first(n)` | Matches `View.first`; "take" sounds like it removes them. |
| `for_each` | `each` | Already PROTOCOLS' word for the derived bundle. |
| `IntoIterator` | `Listable` | Named for the primitive you implement (`list`), not for a conversion. |
| `next()` | *(gone)* | Nim's `iterator` is the primitive. No manual state machine to write. |

## In use

```nim
# diff-patch: which lines actually differ, then the hunks around them
let changed = zip(oldLines.list(), newLines.list())
                .numbered()
                .keep(proc (p: auto): bool = p[1][0] != p[1][1])

# math-toolkit-cli: parse-then-total, bailing on the first bad cell
let total = column.list()
              .map(parseMoney)
              .tryReduce(0'i64, proc (a: int64, c: Option[int64]): Option[int64] = a.tryAdd(c.get(0)))
total.ifSome(cents): echo "sum: ", cents
```

## Vocabulary exceptions
`reduce`, `map`, `zip`, `keep`, and `drop` are domain verbs for sequence transformation — the structural table covers *access* to a collection, not transformation of a stream. Each is one word, subject first. `first(n)` overloads a name PROTOCOLS' derived bundle already uses for "the single first item"; that is intentional, since the two meanings differ only by whether you pass a count.
