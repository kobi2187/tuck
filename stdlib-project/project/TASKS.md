# TASKS: stdlib build order, priority-sorted

Single-agent session — no subagent fan-out. Tasks executed serially, in this
order, each one committed before the next starts (per standing "commit after
every success").

## T-01: core.iter
Status: DONE
Maps to: MAP.md core.iter
Interfaces: `stdlib-project/modules/core/iter/API.tuck.md` — updated, stale
  parse-failure section removed
Acceptance criteria:
- [x] `stdlib-project/modules/core/iter/iter.tuck` implements map/filter/
      reject/take/skip/numbered/zip/append/prepend/concat/reverse/reduce/
      each/find/any/all/sum/sort, all via plain `:fnRef` params (no bake
      dependency). `count` intentionally not re-declared — owned by alloc.vec.
      `sum`/`sort` scoped to `int`, not generic (see API.tuck.md note —
      no constraint mechanism yet to bound `T` to `+`/`>`)
- [x] `./tuck ch` OK
- [x] hostBuilds + runs 0 on all three backends (own self-check `main`)
- [x] API.tuck.md updated

Follow-ons filed, not blocking, not scheduled this pass:
- `bake` drops fields into a raw tuple instead of the record's nominal type
  (worse in the generic case: silently drops fields not named in the call)
- receiver-postfix generic calls (`xs.filter {...}`) don't infer `T`;
  payload-prefix (`{items: xs, ...} filter`) does

## T-02: core.array
Status: DONE
Maps to: MAP.md core.array
Interfaces: `stdlib-project/modules/core/array/API.tuck.md`
Acceptance criteria: same bar as T-01 — all met.

Turned out NOT blocker-free: Array[N,T] had never been indexed, sized, or
constructed from a literal anywhere in the corpus. Four compiler bugs found
and fixed (commit 672f6f6): no indexing primitive existed (bracket sugar
self-recurses through a Tuck-body `at`), `.len` failed on Odin/D for Array,
list literals always built a Seq even against a declared Array[N,T] field,
D's generic template params didn't distinguish a size value from a type.
Then a FIFTH, unrelated to Array specifically (commit e973a25): a Tuck
module literally named `array` collides with Nim's builtin `array[N,T]` —
general fix, benefits any future module named after a Nim builtin
(`seq`/`set`/`string`/...).

## T-03: core.types
Status: pending
Maps to: MAP.md core.types
Interfaces: `stdlib-project/modules/core/types/API.tuck.md`

## T-04: core.error
Status: pending
Maps to: MAP.md core.error
Interfaces: `stdlib-project/modules/core/error/API.tuck.md`

## T-05: core.fmt
Status: pending
Maps to: MAP.md core.fmt
Depends on: core.convert (done)
Interfaces: `stdlib-project/modules/core/fmt/API.tuck.md`

## T-06: core.slice
Status: pending — needs a ruling first
Maps to: MAP.md core.slice
Blocked on: what interface shape backs "Indexable" — user's own framing
  ("wrt slicing, we can get it via simple for loop and indices... this also
  drives us to have an interface, like indexable or whatever name") was left
  at "let's tackle another issue". Needs a short explanation + ruling before
  work starts, per [[explain-fully-before-ruling]].

## T-07: alloc.fmt
Status: pending
Depends on: T-05 (core.fmt)

## T-08: group Sortable/Hashable — unify primitives and records under one bound
Status: pending
Depends on: `group` (shipped, `tests/suites/groups.nim`)

`group` satisfaction is structural: any free `fn compare({self: T, other: T})
-> Order` matching shape satisfies `T: Sortable`, checked per instantiation,
no attach statement. Costs nothing at runtime either — Tuck monomorphizes
generics per concrete `T`, so `{self: a, other: b} compare` resolves to the
concrete overload at the call site same as any other overloaded call; `group`
only adds the compile-time check that the overload exists before codegen. Design: give `int`/`str` explicit `compare`/`hashOf`
overloads in core.cmp/core.hash so primitives satisfy `Sortable`/`Hashable`
for free, same as any record that defines its own `compare`/`hashOf`. That
unifies two currently-separate paths:
- `core.cmp`'s `smaller`/`larger`/`clamped[T]` and `core.iter`'s `sort[T]`/
  `sum[T]` all use bare `<`/`>`/`+` on an unconstrained `[T]` — their own
  comments say "no constraint mechanism yet", which predates `group` and is
  now stale.
- `alloc.set`/`alloc.map` scan linearly with `==`, blocked from hashing
  because there was no way to require `hashOf` — `group Hashable` removes
  that block.

Once primitives carry `compare`, add `sortBy`/`min`/`max[T: Sortable]` to
core.cmp — real verbs, not possible on top of bare `<` for arbitrary records.

Docs marked against this (pre-`group`, needs the rewrite above):
`core/cmp/API.tuck.md`, `alloc/set/API.tuck.md` (its Hashable-blocked note).
`alloc/vec`, `alloc/map`, `alloc/string`'s API.tuck.md had a separate,
unrelated mistake (`..` claimed for a plain value-returning call — it's
builder-mutation only) — fixed directly, not part of this task.

## Blocked — not scheduled this pass (resource registry, spec §7.4)
- core.mem, core.ptr — need the resource registry
- core.atomic, core.sync-cell — need [nocopy]/F25 (non-copyable values)
- alloc.box, alloc.rc, alloc.allocator — need the resource registry

## Out of scope this pass
Everything under platform/*, most of std/*, sys/* beyond small deltas — see
MAP.md's out-of-scope section for the full list and reasons.
