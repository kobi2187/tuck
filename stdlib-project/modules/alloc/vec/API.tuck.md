# alloc.vec — Tuck translation

## Shape decision
Freeform `pending:` verbs over the built-in `Seq[T]`. No new container type
— `Seq[T]` already *is* Tuck's growable sequence, and adding a `List[T]`
wrapper beside it would be the "second thing that means the same thing"
`PROTOCOLS.md` forbids.

**Compiler-verified**, `./tuck ch`: `OK`, 13/13 `PENDING`.

## The API

```tuck
pending:
  fn push[T]({items: Seq[T], value: T}) -> Seq[T]
  fn pop[T]({items: Seq[T]}) -> {rest: Seq[T], value: T}?
  fn insertAt[T]({items: Seq[T], index: int, value: T}) -> Seq[T]
  fn removeAt[T]({items: Seq[T], index: int}) -> Seq[T]
  fn at[T]({items: Seq[T], index: int}) -> T?
  fn setAt[T]({items: Seq[T], index: int, value: T}) -> Seq[T]
  fn count[T]({items: Seq[T]}) -> int
  fn isEmpty[T]({items: Seq[T]}) -> bool
  fn clear[T]({items: Seq[T]}) -> Seq[T]
  fn first[T]({items: Seq[T]}) -> T?
  fn last[T]({items: Seq[T]}) -> T?
  fn has[T]({items: Seq[T], value: T}) -> bool
  fn indexOf[T]({items: Seq[T], value: T}) -> int?
```

## Notes on the translation
- **`List[T]` is dropped as a name.** The Nim pass renamed `Vec<T>` →
  `List[T]` to match "Nim's own familiar vocabulary"; in Tuck the familiar
  vocabulary is `Seq[T]`, which already exists, so the rename lands on
  nothing. `at`/`setAt` deliberately match the real `std/seq.tuck` spellings
  rather than inventing new ones.
- **Every mutator returns the new value.** `push` doesn't append in place —
  value semantics (`TK-TY15`) forbids writing through a parameter. This is
  the single biggest ergonomic difference from the Nim design and it is
  pervasive here, since this module is *all* mutators.
- **`pop` returns `{rest, value}?`** rather than mutating and returning the
  element. One optional payload carries both halves; absence means empty.
- **`Grid[T]` (the flat-backed 2D table added in round 2 for
  `diff-patch`'s Myers table) is not translated.** It needs a stride and
  `(row, col)` indexing over one flat buffer; expressible as a record over
  `Seq[T]` with `width`, but whether that earns a type — versus a
  documented convention, which is what `core.array` already chose for the
  fixed-size case — is an open question rather than an obvious yes.
- **The allocator parameter is gone** — see `alloc.allocator`: memory
  regions are `pool`/`arena` declarations, not values threaded through
  signatures.

## The open cost question

`push` returning a new `Seq[T]` currently emits as a plain Nim value
parameter and return:

```nim
proc tuck_addOne*(items: seq[int], value: int): seq[int] =
```

No `var`, no `sink`, no `openArray` — so today each call is a real copy,
and an append loop is O(n²). This affects `alloc.string`, `alloc.deque`,
`alloc.map` and `alloc.set` identically, since all are "mutate a
container" modules.

**This is a codegen question, not a settled semantic.** How `Seq` crosses a
call boundary is Tuck's own decision to make — nothing here should be read
as importing Nim's or Rust's answer.

**`..` was assumed to work here — it does not.** Checked directly:
`xs ..push {value: 4}` is rejected, "missing required field 'items'".
`..` is for actual mutation — an object's own `self..field`, a real
builder — and `push` isn't one; it takes `items` as an ordinary param and
returns a new `Seq`, same as everything else here. Call-site spelling is
plain reassignment:

```tuck
var xs = [1, 2, 3]
xs = {items: xs, value: 4} push
```

**Whether that's fast is settled, not open.** This was flagged as an open
backend question — it isn't anymore. The compiler now detects exactly this
shape (`xs = {items: xs, ...} push`) and appends in place instead of
copying; measured O(n) instead of O(n²) on all three backends
(`benches/containers`).
