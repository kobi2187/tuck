# Integration: how any of this actually loads into the compiler

`GOVERNANCE.md` draws the three rungs — what ships with the compiler, what's
blessed-but-separate, what's left to the ecosystem — and names, as a loose
end of its own, "a fourth question this raises on its own: how not to
fragment if some of `std` becomes 'just interfaces.'" This file is that
answer, and it is also the missing piece the rung model needed anyway: rungs
describe WHO governs a module, but nothing in `GOVERNANCE.md` or
`PROTOCOLS.md` says how a build actually ends up wired to a concrete
implementation of one, or what happens when it isn't. That mechanism is
this document's subject.

It exists because of a concrete, repeated failure this project's own
dogfooding pass hit: a call typechecks cleanly, then breaks two stages later
at the Nim/Odin/D compile (a missing `import seq`, a missing `import str`, a
`.toStr` that only resolves once the right module is in scope). The checker
had no way to say "nothing backs this yet" as its OWN diagnostic, because
`extern` binds to the runtime by bare name convention, not by a checked
contract. Everything below is built to make that failure a real, first-class
compiler error instead.

## The shape

**A capability is an `interface`.** Every module boundary drafted under
`modules/*/API.tuck.md` becomes an `interface` declaration rather than a bare
`extern` block — `interface Fs: fn readFile({path: str}) -> !{content: str}
[error: FsError]`, and so on for each fn a module currently exposes.

**A package is one or more tagged, `satisfies`-conforming objects.** A
package backs an interface by declaring an `object` and using `satisfies` —
Tuck's existing conformance mechanism, unchanged. What's new is that a
package also carries a TAG SET describing what it's suitable for, inherited
by everything it satisfies. These tags are their OWN, ad hoc vocabulary —
not a generalization of Tuck's effect attributes (`[io]`, `[no_alloc]`,
`[irq_safe]`, `[may_block]`). Effect attributes are a per-function, checker-
enforced contract about what a body of code DOES; package tags are a
per-package, resolver-level label about what a package is SUITABLE FOR
(`portable`, `realtime`, `embedded`), unrelated machinery even where a name
might look similar. They may still mirror this project's tier split (`core`,
`alloc`, `std`, `sys`, `platform`) as a starting vocabulary, but that's a
naming convenience, not a reuse of the effects system.

**Packages can introduce NEW interfaces, not only implement existing ones.**
This is not a special case — it's the default expectation. `std` does not
own the closed set of capability shapes any more than Go's standard library
owns every interface any Go package is allowed to define. A third-party
crypto package declaring `interface Signer` is exactly as legitimate as one
providing `object Ed25519 satisfies Signer` for its own new interface, or
`satisfies Hash` for an existing one from `core/hash`.

This looks like it cuts against `GOVERNANCE.md`'s own Go lesson — "standardize
the contract at rung A; let rung B/C compete on implementation underneath
it" — but it doesn't, once the lesson is read precisely. `database/sql`'s
point is narrower than "only std may define interfaces": it's that an
ALREADY-SHARED, cross-cutting contract (the one thing every SQL driver needs
to agree on) must not fragment into five incompatible near-duplicates. It
says nothing against a package inventing a genuinely new capability nobody
shared a contract for yet. The rule this project should state precisely,
then, is: **a rung-A interface may not be redefined at rung B/C — if a
capability already has a blessed shape, competing packages implement THAT
shape, they don't each define their own** (this is `satisfies`, already
enforced structurally). A wholly new capability has no such constraint,
because there is nothing yet to fragment.

**A build declares required tags; resolution matches against them.** Default
is permissive — an unconstrained build accepts any tag-compatible package,
which is what keeps the offline-weekend-project path a zero-config default
(see below). A build targeting embedded/no-alloc work states its
requirement (`core, no_alloc`, or similar ad hoc list — exact spelling and
syntax TBD, and deliberately NOT the `[...]` effect-attribute bracket, to
keep the two mechanisms visually as well as semantically separate). This
could ride the same `--target`/`when TARGET` lever
`tests/suites/when_target.nim` already exercises, generalized from "which
conditional block" to "which package" — or it could be its own flag
entirely; not decided. Resolution only considers packages whose tags
satisfy the build's stated requirement.

**The diagnostic this whole mechanism exists to produce**: using a
capability with no tag-matching, interface-satisfying package wired into the
current build is a checker-level error — "no package satisfying `Fs` is
tagged `portable`" — not today's silent pass-then-fail-three-stages-later.
This directly retires the failure mode named in the opening section.

## Default path: the offline weekend project

Nobody chooses a package unless they want to override one. A reference
package per rung-A interface ships pre-selected as the build's default —
mechanically, this is exactly what today's `std/*.tuck` + `tuck_rt.*` already
are, just made explicit as "the default package satisfying this interface"
instead of "the only implementation that exists." A developer with no
network, no registry, writing a weekend CLI tool gets precisely today's
experience: `import fs`, it works, no resolution step ever becomes visible.

## Sequencing: what has to be fixed first

Interface dispatch is currently broken for any method whose payload has
fields beyond `self` — found independently by two apps in this session's
dogfooding pass (`doc-convert-tester`, `config-schema-validator`).
`genIfaceDispatch` (`compiler/codegen.nim`, ~line 465) packs the extra
payload into a Nim named tuple at the call site while the concrete
implementer is emitted expecting those same fields splatted as separate
positional params — a real arity mismatch, not a design gap. Since nearly
every real capability fn in `stdlib-project`'s drafted modules has payload
beyond `self` (`readFile({path: str})`, `hash({data: str})`, ...), this bug
is not one more entry on a list — it is a precondition. This whole design
leans on `interface` dispatch for the entire stdlib surface, and that
dispatch does not work today for the shapes this design needs most. Fix
this before any module gets reframed as an interface, or every reframed
module inherits a broken call path on day one.

## Migration, not rewrite

Today's `std/` (8 files: console, fs, net, scheduler, seq, str, sys, time,
plus `random`/`hash`/`math` added this session) was scaffolding used to
build the compiler itself, never intended as the permanent stdlib —
confirmed directly this session. Under this scheme it becomes the FIRST
reference package, not a special case the compiler hardcodes around. The
tiered replacement this project (`stdlib-project/`) exists to design gets
built out module by module against this same mechanism from the start,
rather than accumulating as another set of bare `extern` blocks that would
need this same retrofit a second time later.

## Open questions, not resolved here

- Exact tag spelling and where it's declared on a package (its own
  package-level block or manifest file, deliberately distinct from a
  decl's `[io]`-style effect-attribute list — undecided).
- Whether tag requirement is stated per-build (a CLI flag, `--target`-style)
  or per-`import` (closer to source-level opt-in) — this session's
  discussion leaned toward per-build, matching the offline-default goal, but
  it wasn't settled to the level a written contract needs.
- Ambiguity behavior when MULTIPLE tag-compatible packages satisfy the same
  interface in one build — first-registered wins, explicit disambiguation
  required, or something else. Not discussed.
- How a package registers itself into a build at all — this document
  assumes such a mechanism exists (an import, a manifest entry, a build
  flag) without specifying it; that's a real, unaddressed gap.
