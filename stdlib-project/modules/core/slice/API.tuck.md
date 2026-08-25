# core.slice — Tuck translation

## This module does not translate. That is a finding, not a gap.

`core.slice`'s entire premise is `View[T]` — *"a borrowed (start, length)
window. Copyable, never owning, never resizing"*, implemented as
`start: ptr T` plus `length`. **Tuck forbids exactly this by design.**

From `LANGUAGE-OVERVIEW.md`'s pointer rule:

> A pointer may be produced by an extern and consumed by another extern,
> but it **may never be stored.** … illegal in a record field, a plain fn
> signature, a `Seq` element, a mixin member, or an actor field.

`tests/suites/pointer_containment.nim` is described as the most systematic
negative test in the whole suite (196 lines) enforcing it. And the spec's
Tier-1 rationale is explicit about why: *"No `ref` in Tier 1, so no two
names ever denote one record. A data race needs two references to one
mutable location; the sentence cannot be formed."* A borrowed view is
precisely two names denoting one buffer — the sentence Tuck is built not
to be able to say.

So `View[T]` is not merely unimplemented here; it is the thing the
language's safety argument spends its budget forbidding.

## What replaces it

Tuck's own answer is already visible in the real `std/*` modules: pass
`Seq[T]` (or `Array[N, T]`, or `str`) **by value**, and rely on rule #4 —
records are *"passed without copying… both backends emit a pointer; the
guarantee is in the checker, not a copy."* That is the same zero-copy
outcome `View[T]` was designed to get, obtained by a checker rule instead
of a stored pointer, with no way for the caller to write through it
(`TK-TY15`).

So the operations `core.slice` defined don't disappear — they move:

- `count`/`isEmpty`/`get`/`first`/`last`/`list`/`numbered` — belong on
  `Seq[T]` directly, and several already exist as `std/seq.tuck`'s
  `at`/`setAt`.
- `chunks`/`windows`/`splitAt`/`slice` — these are real, useful, and worth
  having as `Seq[T] -> Seq[Seq[T]]` functions (verified those signatures
  typecheck in `core.array`'s file), but note the honest cost: each result
  is a *value*, so what was a free re-windowing in the Nim design is a real
  copy in Tuck. That is the price of the safety argument above, and it
  should be stated in whatever module ends up owning these rather than
  hidden.

## Recommendation, not taken unilaterally
`core.slice` should probably be **deleted as a module** and its verbs
merged into `core.array`/`std.seq`, since the type it exists to define
cannot exist. Flagged rather than done: deleting a module from the design
corpus is exactly the kind of call worth confirming, and the *operations*
are all still wanted even though the *type* isn't.
