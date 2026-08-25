# alloc.box — Tuck translation

## This module does not translate, and that is the finding.

`Owned[T]` is *"put one value on the heap, with exactly one owner, in the
allocator of your choosing. For values too big for the stack, for recursive
types, and for anything you want living in an arena."* Three motivations,
and Tuck answers each without a box type:

- **Too big for the stack** — a record is *"passed without copying; both
  backends emit a pointer"* (rule #4). The indirection a `Box` exists to
  add is already there, invisibly and safely.
- **Recursive types** — genuinely unresolved. A `type Node = {next: Node}`
  needs indirection Tuck has no way to request, since `ref` doesn't exist
  in Tier 1. See `alloc.list`, which is the same gap in sharper form.
- **"Living in an arena"** — `arena`/`pool` are language declarations
  (`ScratchSpace.alloc Array[128, u8]`), not a value you wrap.

And the type itself cannot be written: `Owned[T]` is a stored pointer,
which the containment rule forbids in a record field
(`tests/suites/pointer_containment.nim`).

## Recommendation
Drop as a module. Carry the **recursive-type question** forward — it is
real, and it is the one thing here that neither rule #4 nor `arena` covers.
