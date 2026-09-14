# The Resource Registry — implementation plan

Issue #32. Design: `tuck-spec.md` §7.4 plus the user rulings of 2026-07-11 in
`ROADMAP.md`. This file is the *implementation* half: what gets built, in what
order, and which design questions the spec left open — with the answer this
tree commits to and the reason for it.

Read §7.4 first. Nothing here re-states it.

---

## 0. What the spec left open

Four questions had to be answered before any code. The spec is the authority on
everything else; these are the places it was silent or said two things.

### 0.1 Where does `policy` live — the block, or the kind?

§7.4 says the close policy mirrors the `errors` declaration (§4.9), which is
**global**: `errors [policy: strict]`. But issue #32's own reproducer puts it on
the kind:

```tuck
resources:
  udp [policy: strict]
```

**Settled: per kind, with a block-level default.**

```tuck
resources [policy: lazy]:      # the default for every kind below
  net  [cap: 10_000, on_full: error, sweep_batch: 100]
  file [cap: 8, on_finish: flush, policy: strict]   # ...overridden here
  udp
```

Per-kind subsumes global, so nothing is lost, and it is the form the issue
asks for. The block default keeps the common case a single word. A kind naming
no policy and sitting in a block that names none is `strict` — the embedded and
debug default §7.4 already picks.

This is *not* a departure from the errors-decl symmetry: the symmetry §7.4
invokes is about the **vocabulary** (a declared, named close policy rather than
an inferred one), not about the scope it is declared at.

### 0.2 One `resources:` block, or many?

**Settled: many, across modules; kinds accumulate program-wide.**

§7.4 is explicit that kinds are "an open set — a UDP library declares its own
kind the same way a module declares its error enums". A library that cannot
declare its own kind is not an open set. Two blocks declaring the *same* kind
name is an error (TK-RS02), because the second one's attributes would silently
lose to the first.

### 0.3 What does the user's code actually hold?

§7.4: a handle is "a plain value (slot index + generation counter), copyable,
comparable, Tier 1 safe". §7.2's `PoolHandle` is already exactly that, and its
doc comment in `compiler/tuck_rt.nim` already says it is reached through 7.2's
machinery "which 7.4 says is the same machinery".

**Settled: each kind emits a `<Kind>Handle` type, an alias of the runtime's
`ResourceHandle`**, exactly as each pool emits a `<Pool>Handle` alias of
`PoolHandle`. The checker keeps two kinds' handles apart; the backends need
only the one runtime type.

What §7.4's `fn open(...) -> UdpSocket! [io, resource: udp]` means, then, is
that `UdpSocket` is the *library's* name for `UdpHandle` — a `distinct`, or a
plain alias. The marker does not rewrite the return type. **This is the one
place the prototype deliberately stops short**: making the checker *verify*
that an acquiring fn returns something handle-shaped needs the type-level work
Phase 5 sets up, and doing it early would guess wrong. Until then the marker is
a declaration of intent that the flow check (Phase 5) enforces positionally.

### 0.4 Is `defer` a registry feature?

**No — `defer` is a general statement, and the registry rides on it.**

§7.4 says "`defer` is release intent, not release", which is a statement about
what a defer block *containing a release* means, not a claim that defer exists
only for resources. Tuck has no `defer` at all today. Building one that only
works inside a resource block would be the "clever reuse" the tree's own
invariant warns about.

It also happens to be nearly free: Nim has `defer:`, Odin has `defer`, D has
`scope(exit)`. All three are scope-exit-ordered and LIFO. The backend arm is a
keyword swap, not a lowering.

---

## 1. The stages

Each is a commit that leaves the tree green. Ordered so that every stage is
testable on its own, and so the *front* of the pipeline settles before the
runtime it drives is written — the opposite order produces a runtime designed
against a guess.

| # | Stage | Touches |
|---|-------|---------|
| 1 | Parser | `ast.nim`, `parser.nim`, `parser_decl_kinds.nim`, `parser_expr.nim` |
| 2 | Checker | `typecheck_collect.nim`, `typecheck.nim`, `semantics.nim`, `diagnostics.nim` |
| 3 | Runtime | `tuck_rt.nim`, `tuckrt/`, `tuckrt_d/` |
| 4 | Codegen | `codegen_decl.nim`, `codegen_odin_decl.nim`, `codegen_d_decl.nim` + the three expr arms |
| 5 | Flow + report | `typecheck_flow.nim`, `tuck.nim` |
| 6 | Docs | `tuck-spec.md`, `LANGUAGE-OVERVIEW.md`, `ROADMAP.md`, `examples/` |

### Stage 1 — Parser

`dkResources`, its own decl kind (per the tree's invariant — a `resources:`
block is not an `errors` block with a list in it):

```nim
of dkResources:
  resKinds*: seq[ResourceKindDef]
```

`ResourceKindDef` carries `name`, `cap` (0 = unbounded), `policy`, `onFull`,
`onFinish`, `sweepBatch`, and its `span`. The attribute bracket is read with
the existing `parseDeclAttrs` — `[cap: 10_000, on_full: error]` is the same
shape `pool` and `actor` already use, so there is no new attribute grammar.

`resource:` joins `error:` and `emit:` as the third **valued** attribute folded
into the effect bracket. That is the established seam: `parseEffectList`
already special-cases the two attributes that carry a value, because
`EffectMarker` is a valueless enum and cannot hold a kind name. A fn grows
`fnResourceKinds*: seq[string]`, parallel to the existing `fnErrTypes`.

`defer:` becomes `exkDefer`, holding one body expression.

### Stage 2 — Checker

- `collectResourceKinds` builds the program-wide kind table, rejecting a
  duplicate (TK-RS02) and a malformed attribute (TK-RS03).
- An unknown kind in `[resource: k]` is TK-RS01 — §7.4: "same as an undeclared
  error enum".
- `semantics.nim` propagates the marker to callers with the rest of the effect
  set, so a fn calling an acquiring fn must declare the kind itself. §3.7:
  explicit, not inferred.

A new `RS` diagnostic category, registered at the end of `diagnostics.nim` as
the permanence rule requires.

### Stage 3 — Runtime

`ResourceTable` in each of the three runtimes: a slot array of
`{ref, gen, finished, site}`, an occupancy mask, a finished count, and the
kind's knobs. Operations: `acquire`, `finish` (mark + `on_finish` + generation
bump + the inline watermark check), `sweep`, `closeAll` (LIFO), and `deref`
(the stale-handle check, which is the whole point of the generation).

Unbounded kinds are seq-backed, capped kinds array-backed — §7.4's link-time
memory budget.

### Stage 4 — Codegen

`dkResources` emits one table per kind plus its `<Kind>Handle` alias.
`exkDefer` emits the host's native defer. Then `tools/emit_examples.sh` and
read `git diff examples/` — that diff is the review.

### Stage 5 — Flow and report

The scope-local check §7.4 describes: every acquire ends in a defer mark or an
escape (stored or returned). Escape is sound *because* the registry closes at
exit, which is what makes the local analysis sufficient — no alias analysis.

`OPEN RESOURCES (n)` joins PENDING and SHORTCUTS in `checkOrDie`.

### Stage 6 — Docs

The two §7.4 blocks are fenced ` ```tuck-rejected ` today. `tools/doc_snippets`
fails the build when such a block *starts parsing*, so Stage 1 forces this
stage — the gate will not let the feature land undocumented.

---

## 2. What is deliberately not in the first pass

Written down so a later reader does not read an intended boundary as a gap:

- **The acquiring fn's return type is not verified** — §0.3.
- **`kind::sweep` as a call** lands with Stage 3's runtime op, but the
  scheduled-cleanup story (§7.4's "a dedicated sweeper actor is a possible
  opt-in once actors land") stays opt-in and unwritten.
- **`on_full: error`** needs the kind to name an error enum to raise. Until
  then the honest policies are `error` (abort with a named message) and the
  default, absence.
