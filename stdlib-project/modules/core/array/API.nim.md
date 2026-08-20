# core.array — Nim API

## Purpose
Fixed-size, value-typed collections whose length is part of their type — a 32-byte key, a 9x9 board, a hardware register block. They live on the stack, copy by value, and never allocate.

## Protocols implemented
`Gettable[Index, T]`, `Settable[Index, T]`, and the read-only half of `Collection[T]` (`list`, `count`). No `add`/`remove`: the length is in the type, so nothing can be inserted or taken out. Nim's built-in `array[N, T]` *is* the type; this module supplies the vocabulary, not a wrapper.

## The API

```nim
type
  Grid*[R, C: static int; T] = array[R, array[C, T]]
    ## Just an alias — a nested array already indexes as `g[row][col]` for free.
    ## It exists so `(row, col)` ordering is written down once, matching alloc.vec's Grid.

func count*[N: static int, T](a: array[N, T]): Count   ## always N, known at compile time
func get*[N: static int, T](a: array[N, T], i: Index): Option[T]
proc set*[N: static int, T](a: var array[N, T], i: Index, value: T)
func `[]`*  ## Nim's built-in indexing; raises on a bad index

func filled*[N: static int, T](_: typedesc[array[N, T]], value: T): array[N, T]
  ## Every slot set to the same value. `filled(array[9, Cell], allCandidates)`
func built*[N: static int, T](_: typedesc[array[N, T]],
                              make: proc (i: Index): T {.nimcall.}): array[N, T]
  ## Every slot computed from its position. The workhorse constructor.

func mapped*[N: static int, T, U](a: array[N, T],
                                  transform: proc (x: T): U {.nimcall.}): array[N, U]
  ## Same length, new element type — the length survives the transform.
func pairedWith*[N: static int, T, U](a: array[N, T], other: array[N, U]): array[N, (T, U)]

iterator list*[N: static int, T](a: array[N, T]): T
iterator numbered*[N: static int, T](a: array[N, T]): (Index, T)

func view*[N: static int, T](a: array[N, T]): View[T]
  ## Zero-cost borrow into core.slice — search, sort, chunk all come from there.
proc edit*[N: static int, T](a: var array[N, T]): var View[T]

func get*[R, C: static int; T](g: Grid[R, C, T], row, col: Index): Option[T]
proc set*[R, C: static int; T](g: var Grid[R, C, T], row, col: Index, value: T)
iterator row*[R, C: static int; T](g: Grid[R, C, T], r: Index): T
iterator column*[R, C: static int; T](g: Grid[R, C, T], c: Index): T
  ## Named separately from `row` on purpose: a column is *not* contiguous in memory.
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `splat(value)` | `filled(T, value)` | "Splat" is SIMD jargon that leaked into a general API. `filled` needs no explanation. |
| `from_fn(f)` | `built(T, make)` | "From fn" describes the argument; `built` describes the result. |
| `map` | `mapped` | Nim convention: `mapped` returns a new array, a bare `map` would suggest in-place. |
| `zip(other)` | `pairedWith(other)` | Says what you get back. `zip` is guessable only if you already know it. |
| `as_slice` / `as_mut_slice` | `view` / `edit` | The mutable one gets a verb that says *why* you want it, instead of an `mut` marker. |
| *(none)* | `Grid[R, C, T]` | Added as a pure alias, not a type: it pins the `(row, col)` convention shared with `alloc.vec.Grid` without adding a wrapper — the original file's "no `Grid2D`" decision, kept. |
| *(none)* | `column` | New. It's the one grid access that isn't cheap, so it gets a name that can carry that warning in its doc comment. |

## In use

```nim
# sudoku-solver: the board, and the 27 constraint groups, all on the stack
type Board = Grid[9, 9, Candidates]
var board = filled(array[9, array[9, Candidates]], allDigits)

board.set(4, 4, onlyDigit(7))
echo board.get(0, 0).get(allDigits).count

# each group's nine coordinates, computed once at compile time
const groups = built(array[27, array[9, (Index, Index)]], groupCoords)
for cell in groups[18].list():          # box 0
  board.get(cell[0], cell[1]).ifSome(c): eliminate(c, 7)
```

## Vocabulary exceptions
`filled`, `built`, `mapped`, and `pairedWith` are domain verbs for construction and shape-preserving transformation; the structural table has no constructor verb at all (`copy` is the closest and means something else). All four take the target type first and options last.
