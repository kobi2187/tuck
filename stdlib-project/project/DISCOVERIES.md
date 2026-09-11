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
