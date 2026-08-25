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

**`..` is the right call-site spelling — verified.** `xs ..push {value: 4}`
typechecks and lowers to:

```nim
var xs = @[1, 2, 3]
xs = tuck_push(xs, 4)
```

So the signatures above are correct as written, and callers use `..` rather
than rebinding by hand:

```tuck
var xs = [1, 2, 3]
xs ..push {value: 4}        # not: xs = {items: xs, value: 4} push
```

That is the idiomatic Tuck shape (`server ..withDefaults ..port {8080}` is
the same pattern), and it reads far better than the rebinding form.

**Whether it is also *fast* is a backend question this pass could not
settle.** `xs = tuck_push(xs, 4)` is a self-assignment: Nim's ARC/ORC may
be able to move rather than copy, since `xs`'s old value is dead
immediately after. If it does, appends are amortized O(1) and there is no
problem at all. If it doesn't, the loop is O(n²).

**Recommended next step:** benchmark an append loop (`benches/` already
exists for exactly this kind of question) before committing the whole
`alloc` tier to this shape. If the copy is real, the fix is a compiler
one — teach lowering to emit an in-place mutation for `..` on an owned
`var` — not an API redesign, since the spelling above is already right.
