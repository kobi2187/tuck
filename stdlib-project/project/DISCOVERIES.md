# Discoveries (append-only)

- `:fnRef` didn't match a generic fnsig parameter (`Mapper[T,U]` slot, tkApp)
  — only non-generic named fnsigs (tkNamed) were handled. Fixed
  `typecheck_compat.nim` + `typecheck.nim` (inferBindings gained a fnsig-slot
  arm). Committed `35817b9`.
- `bake` returns a structural tuple, not the record's nominal type — checker
  accepts `let q: Query = x bake {...}`, Nim rejects the emitted tuple against
  the declared object type. Worse in the generic case: carried-over fields are
  silently dropped from the emitted tuple. Plain construction
  (`{...} TypeName`) does NOT have this bug — it goes through the real
  constructor. `core.iter` doesn't need bake fixed to ship.
- `xs.filter {test: :isPositive}` (receiver-postfix form) fails to infer `T`
  — `expects Seq[T] but the receiver is Seq[int]`. Payload-prefix form
  (`{items: xs, test: :isPositive} filter`) infers fine. Same verb, two call
  syntaxes, one broken inference path. Narrow, not iter-blocking.
- `core.iter`'s API.tuck.md doc is STALE: says `fnsig Mapper[T, U] = ...`
  fails to parse. It parses; the doc predates the generic-fnsig-on-Odin/D work.
- Language feature landed (compiler commit 4379a0b, not stdlib-project
  scoped): `group` — spec §5.5, a named/nominal compile-time-only bound for
  generics (`fn sort[T: Sortable]`). Grew directly out of the interface
  survey below: `core.cmp`'s `interface Sortable` is now the wrong
  declaration kind for what it's used for — should become `group Sortable`
  (drops the never-used dispatch machinery it never needed) — not done yet,
  next natural step once this pass resumes.
  - Also usable inline on a parameter's own type: `{item: Sortable +
    Hashable}`, no generic-param-list ceremony needed.
  - FIXED (commit 8379955): `{x: expr} f.someField` now rejected —
    TK-TY23. Ruling: only a call/ctor may follow `{payload}`, nothing
    chains onto the result. First attempt (gate on capitalization in the
    parser) broke `examples/31`'s legitimate `{a,b} c.add` slot call —
    `lowercase.lowercase` in both cases, undecidable without name
    resolution. Real fix is in the checker (`asIndirectCall`), not the
    parser.
- Proposed extending done modules (user: "propose... very useful
  primitives... match the vision/style/idioms"). Two of four proposals were
  WRONG on inspection, both caught by verifying before building:
  - `core.convert.intToStr` — already exists as `std/str.tuck`'s generic
    `toStr[T]`, explicitly noted in convert.tuck's own header ("WHAT IS NOT
    HERE, ON PURPOSE"). Verified it actually works (all 3 backends) rather
    than trusting the comment.
  - `core.cmp.Comparator[T]` fnsig for a generic `core.iter.sortBy` — turned
    out unnecessary: `cmp.smaller[T]`/`larger[T]` already prove an ordinary
    bound `[T]` generic works fine with bare `<`, so `sum`/`sort` just
    needed to BE generic, no fnRef indirection needed. Direct steer: "you
    must figure out the correct primitives, even if we do a top-down
    design" — landed on the simpler, already-proven mechanism instead.
  - Built: `core.num` (sign/absI64/midpoint), `core.hash` (hashBytes as the
    real primitive + hashU64, prompted directly: "hash should of course be
    based on bytes").
  - Factor-lang's stdlib named as inspiration for a FUTURE round (user: "too
    many modules, but get inspiration for cool functionality") — not
    consulted yet, noted for next pass.
- `Array[N, T]` had never been indexed, sized, or literal-constructed
  anywhere in the corpus before `core.array`. Four bugs, all found spiking
  its first fn: no indexing primitive (bracket sugar routes to whatever
  `fn at` is in scope, self-recursing when THAT fn is the one being
  written); `.len` failed on Odin/D for Array (only Seq/str were checked);
  a list literal always built a Seq even against a declared Array[N,T]
  field (checker/codegen disagreement, silently accepted then rejected by
  every host); D's generic template params never distinguished a size
  VALUE from a type. Fixed together, commit 672f6f6.
- A Tuck module literally named `array` collides with Nim's builtin
  `array[N,T]` — the file's own module identity is the one thing that never
  gets the `tuck_` mangling prefix every symbol inside it gets. Surfaces
  only when a compound generic instantiation (`?Array[N,T]`) sits alongside
  another sufficiently generic-heavy fn in the same file. General fix
  (extends the existing import-time `nimModuleName` alias to the entry
  module's own filename), commit e973a25 — affects any future module named
  after a Nim builtin (`seq`, `set`, `string`, `range`, ...).
- Recursive sum types (`type Node: | Leaf{...} | Branch{left: Node, right: Node}`)
  already work end to end — landed before this session (`57a7e77`, `68674e8`),
  missed because the planning doc describing it as future work
  (`fancy-yawning-karp.md`) was stale and got deleted once confirmed. Direct
  field cycles lower to a synthesized `Seq[T]` handle automatically, no
  annotation. Verified fresh with a Leaf/Branch spike, all 3 backends, exit 0.
- DESIGN RULING (user, 2026-09-12): the stdlib should LEVERAGE Tuck's own
  features rather than port shapes from other standard libraries. `Option` is
  the worked example — Tuck spells absence `T?`, built into the language with
  `.ok`/`.value` narrowing the checker enforces, so an `Option[T]` type is
  redundant vocabulary. (The v2 contracts had exactly that mistake: `Option[V]`
  was an undeclared name that gradual typing swallowed for four commits; fixed
  in 9fbc224 by writing `V?`.) The general form: before adding a stdlib type,
  ask whether a language feature already says it — and if so, the stdlib's job
  is to SHOW that spelling, not to wrap it.
- DESIGN RULING (user, 2026-09-12): what the stdlib contains is decided by
  what the APPS actually need, not by parity with other stdlibs. The apps
  under `stdlib-project/apps/` are the demand signal, in both directions —
  they say which modules earn their place, and they are where Tuck's own
  idioms get demonstrated. A contract nothing asks for is speculative.
