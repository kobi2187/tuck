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
fn reverse[T]({items: Seq[T]}) -> Seq[T]

fn reduce[T, A]({items: Seq[T], start: A, combine: Combiner[T, A]}) -> A
fn each[T]({items: Seq[T], f: Action[T]}) -> void
fn find[T]({items: Seq[T], test: Predicate[T]}) -> T?
fn any[T]({items: Seq[T], test: Predicate[T]}) -> bool
fn all[T]({items: Seq[T], test: Predicate[T]}) -> bool
fn sum[T]({items: Seq[T]}) -> T?
fn sort[T]({items: Seq[T]}) -> Seq[T]
```

Both ARE generic — `core.cmp.smaller[T]`/`larger[T]` already prove `<` on a
properly bound `[T]` works fine, checked honestly at each real call site
against the concrete type. There is no constraint mechanism, and none is
needed here: the earlier concern (a prior draft of this doc scoped both to
`int`, worried this was the same trap as an UNBOUND fnsig type param) was a
different situation entirely — a `fnsig Mapper = {x: T} -> U` with no `[T,
U]` on the fnsig itself really does silently read as `Unknown`, but an
ordinary `fn sort[T](...)`'s `T` is bound and checked, same as any other
generic fn in this file. Verified on all three backends.

`sum` returns `?T`, not a bare `T` starting at 0: a real generic has no
numeric zero to seed an empty fold from. `reduce` is the verb for "I have my
own seed"; this is the one for "just add them up", and an empty `Seq` is
genuinely absent rather than a silently wrong 0.

## In use

**Pass `:fnRef` at the call site, payload-prefix form.** No `bake`, no
declared wrapper record; the fn parameter is typed by the signature in
`filter`'s own declaration, and `T`/`U` infer from the payload's fields:

```tuck
fn isPositive({x: int}) -> bool:
  return x > 0

let live = {items: readings, test: :isPositive} filter
```

The receiver-postfix spelling (`readings.filter {test: :isPositive}`) does
**not** currently infer the generic — `expects Seq[T] but the receiver is
Seq[int]` — a real, separate bug in the receiver-call inference path
(payload-prefix and receiver-postfix are two different codegen entry points
for the same call; only one runs generic binding today). Use the
payload-prefix form until that's fixed.

**A reused query is a plain construction, not `bake`.** Construction goes
through the type's real constructor and keeps its nominal type; `bake`
re-assembles a *structural* record and currently loses both the nominal type
and, in the generic case, silently drops fields not named in the bake call
(compiler bug, tracked separately — not blocking on this module):

```tuck
type Query[T]:
  items: Seq[T]
  test: Predicate[T]

let q: Query[int] = {items: readings, test: :isPositive} Query
let live = {q: q} runQuery
```

## Verification status
Fully verified, all three backends, `./tuck ch` + `hostBuilds` + `runs 0`
(`iter.tuck`'s own `main`). The generic-fnsig gap this section used to
describe (`fnsig Mapper[T, U] = ...` failing to parse) is fixed — it parses
and infers correctly, including the case where a type param (`U` in
`Mapper[T, U]`) appears only in the fnsig's return and has to be inferred
through the `:fnRef`'s own shape rather than from a payload field.

`count[T]` is **not** re-declared here — `alloc.vec` already owns it and
there is no cross-module import path between sibling `stdlib-project/modules`
directories yet, so it stays where it lives rather than being duplicated.

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
