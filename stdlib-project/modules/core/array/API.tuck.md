# core.array — Tuck translation

## Shape decision
Freeform `pending:` functions over Tuck's built-in `Array[N, T]`. No new
container type: `Array[N, T]` already *is* the fixed-size, value-typed,
never-allocating collection this module is about — the same relationship
the Nim design had to Nim's own `array[N, T]` ("Nim's built-in array *is*
the type; this module supplies the vocabulary, not a wrapper").

**Compiler-verified**, `./tuck ch`: `OK`. `Array[512, u8]` already appears
in the spec's own pool example (`pool RxBuffers = Array[512, u8]`), so this
is the language's real fixed-array syntax, not an invention.

## The API

```tuck
type Board = {cells: Array[81, u8]}

pending:
  fn countOf[T]({items: Seq[T]}) -> int
  fn atFixed({b: Board, index: int}) -> u8?
  fn chunk[T]({items: Seq[T], size: int}) -> Seq[Seq[T]]
```

## Notes, and one thing deliberately not translated
- **`get` returning `?T` replaces the Nim design's `Option[T]`** — see
  `core.types`'s finding: `?T` is built in, so absence needs no library
  type.
- **`Grid[R, C, T]` is dropped, consistent with the Nim design's own
  reasoning.** That file explicitly declined to add a real `Grid2D` type
  ("a compile-time-sized nested array already gives free `grid[r][c]`
  indexing"), keeping it as a documentation alias only. Tuck has no type
  alias with static params to write even that much, and inventing one would
  contradict the original decision — so `(row, col)` ordering stays a
  convention shared with `alloc.vec`, documented, not typed.
- **`built`/`mapped`/`filled` take a `fnsig`-typed slot filled by `bake`**,
  the same idiom `core.iter` documents in full — a record field holds the
  per-element operation, `bake` fills it at compile time, `invoke` runs it,
  and the slot emits as a generic param so there's no boxing or dispatch.
  Concretely `fn built[T]({make: IndexTo[T]}) -> Array[N, T]` with
  `fnsig IndexTo[T] = {i: int} -> T`. Blocked on the same recorded gap
  `core.iter` names — generic `fnsig` doesn't parse yet
  (`LANGUAGE-OVERVIEW.md` §13) — so written as intended rather than as it
  compiles today.
