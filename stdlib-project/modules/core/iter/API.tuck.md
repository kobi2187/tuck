# core.iter — Tuck translation

## Shape decision
Freeform `pending:` verbs taking a `fnsig`-typed operation field, filled by
`bake`. This is the module the Tuck idiom changes most — and improves.

## The idiom: a "closure" is a baked record

Tuck has no captured environment. Instead: `fnsig` names a signature, a
record field holds a fn reference (`:name`), `bake` fills slots at compile
time (fn references *and* argument values), and `invoke` runs it. The
function body reads the **record's other fields** — never the enclosing
function's locals — so everything it uses was placed there explicitly. Slots
emit as generic params, so calls through a baked slot are direct: no
boxing, no runtime dispatch, no allocation
(`examples/03-functions-bake.tuck`, run-gated 42).

**This inverts the Nim design's single biggest structural concession.** That
pass recorded: *"Nim's closure iterators allocate, which `core` forbids — so
adapters became inline iterators that fuse into the surrounding `for` loop…
an adapter chain cannot be stored in a variable or returned from a proc.
That is the single biggest structural divergence from the Rust original."*

In Tuck that limitation is gone. A baked adapter **is** an ordinary record:
storable in a variable, passable to a function, returnable, held in a
field — while still costing nothing at runtime. Tuck lands closer to the
original Rust design here than the Nim pilot could.

## The API

```tuck
fnsig Mapper[T, U] = {x: T} -> U
fnsig Predicate[T] = {x: T} -> bool
fnsig Combiner[T, A] = {acc: A, x: T} -> A
fnsig Action[T] = {x: T} -> void

pending:
  fn map[T, U]({items: Seq[T], f: Mapper[T, U]}) -> Seq[U]
  fn filter[T]({items: Seq[T], test: Predicate[T]}) -> Seq[T]
  fn reject[T]({items: Seq[T], test: Predicate[T]}) -> Seq[T]
  fn take[T]({items: Seq[T], n: int}) -> Seq[T]
  fn skip[T]({items: Seq[T], n: int}) -> Seq[T]
  fn numbered[T]({items: Seq[T]}) -> Seq[{index: int, value: T}]
  fn zip[T, U]({items: Seq[T], other: Seq[U]}) -> Seq[{left: T, right: U}]
  fn append[T]({items: Seq[T], other: Seq[T]}) -> Seq[T]
  fn prepend[T]({items: Seq[T], other: Seq[T]}) -> Seq[T]
  fn concat[T]({items: Seq[Seq[T]]}) -> Seq[T]

  fn reduce[T, A]({items: Seq[T], start: A, combine: Combiner[T, A]}) -> A
  fn each[T]({items: Seq[T], f: Action[T]}) -> void
  fn count[T]({items: Seq[T]}) -> int
  fn find[T]({items: Seq[T], test: Predicate[T]}) -> T?
  fn any[T]({items: Seq[T], test: Predicate[T]}) -> bool
  fn all[T]({items: Seq[T], test: Predicate[T]}) -> bool
  fn sum[T]({items: Seq[T]}) -> T
  fn sort[T]({items: Seq[T]}) -> Seq[T]
  fn reverse[T]({items: Seq[T]}) -> Seq[T]
```

## In use

**The ordinary case — just pass `:fnRef` at the call site.** No `bake`, no
declared wrapper record; the fn parameter is already typed by the
signature in `keep`'s own declaration:

```tuck
fn isPositive({x: int}) -> bool:
  return x > 0

let live = readings.filter {test: :isPositive}        # postfix, reads best
let live2 = {items: readings, test: :isPositive} filter   # payload-prefix, same call
```

**`bake` is for when the context is reused** — pre-fill the operation once,
call it many times, or hand the filled record somewhere else:

```tuck
type IntQuery = {items: Seq[int], test: IntPred}
let q = {items: readings} IntQuery bake {test: :isPositive}
let live3 = q filter
```

Here the `IntQuery` annotation is load-bearing: `bake` matches the
signature **declared on the record's slot**, so the record needs a declared
type for the slot to have one. Both forms verified (`./tuck ch`: `OK`). See
`TUCK-TRANSLATION.md` for the checker gap where a mismatched fn reference
is currently accepted regardless.

## Verification status — read this before trusting the block above
**The generic form above does not compile today**, and the reason is a
recorded language gap, not a design error: `fnsig Mapper[T, U] = ...` fails
to parse (`Expected 'Assign' here, found '['` — `fnsig` has no
type-parameter slot, though `fn` and `type` both do). Filed as an `⚠️ OPEN`
callout in `LANGUAGE-OVERVIEW.md` §13. Written here as it *will* read once
that's fixed, per direct guidance.

What **is** verified: the identical API with every `[T]` replaced by
concrete `int` typechecks completely (`./tuck ch`: `OK`, 10/10 `PENDING`),
and `base bake {test: :isPositive}` binds. So the shape is proven; only the
generic spelling waits on the parser.

Avoided deliberately: writing `fnsig Mapper = {x: T} -> U` with bare
unbound `T`/`U`. That *appears* to typecheck, but only because gradual
typing reads them as `Unknown` — the §0 trap where sketch code and a broken
tree look identical. A fake pass would be worse than a recorded gap.

## Notes
- **`Listable[T]` (the "implement `list` and get every adapter") concept is
  dropped** — Tuck's `interface` is explicit-conformance, and these verbs
  take `Seq[T]` directly. Retroactive attachment via top-level `satisfies`
  is available if a real need for a custom source appears.
- **`splitOn` moves out** — it was defined over `View[T]`, which doesn't
  exist here (see `core.slice`); the `str` version lives in `core.str::split`.
- **Terminals return values, adapters return `Seq`.** Consistent with the
  tier's "no *hidden* allocation" ruling: `keep` returning a new `Seq` is
  visibly a new value, unlike Nim's fused inline iterators. Cost is real
  and stated rather than hidden.
