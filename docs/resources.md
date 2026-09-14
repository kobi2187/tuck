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
`onFinish`, `sweepBatch`, and its `span`. The bracket has the same shape `pool`
and `actor` already use, but gets its own reader rather than `parseDeclAttrs`:
that one takes each value with `parseExpr`, and several words in this closed
vocabulary (`error`, `exit`) are reserved attribute names no expression may
contain — so `[on_full: error]` died at "Expected an expression here". Nothing
in the bracket is ever computed.

The lexer learns digit separators here too, because §7.4 writes `cap: 10_000`
and the spec's own block could not otherwise parse.

`resource:` joins `error:` and `emit:` as the third **valued** attribute folded
into the effect bracket. That is the established seam: `parseEffectList`
already special-cases the two attributes that carry a value, because
`EffectMarker` is a valueless enum and cannot hold a kind name. A fn grows
`fnResourceKinds*: seq[string]`, parallel to the existing `fnErrTypes`.

`defer:` becomes `exkDefer`, holding one body expression.

### Stage 2 — Checker

- `collectResourceKinds` builds the program-wide kind table, rejecting a
  duplicate (TK-RS02).
- An unknown kind in `[resource: k]` is TK-RS01 — §7.4: "same as an undeclared
  error enum".
- `semantics.nim` propagates the marker to callers (TK-RS03) with the rest of
  the effect set — §3.7, explicit not inferred. It rides the SAME walk rather
  than a second one: the pass carries a `Demands` record holding effects and
  kinds together, because a second parallel walk is a second chance to miss a
  node kind, which is a bug that walk has already had once.

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

### Stage 5 — Shutdown and report

`OPEN RESOURCES (n)` at exit, in a debug build: what is still unfinished, and
where it was acquired. Then close-all, in that order — close-all empties the
table, so a report after it is always silent.

Both live in the ENTRY POINT in all three backends rather than an at-exit hook.
Odin cannot use one at all: its entry ends in `os.exit`, which is `_exit` and
runs no finalizer, so an `@(fini)` proc never fires (checked, not assumed). The
entry point already owns the other end of the lifecycle, where it boots the
scheduler.

The static acquire-must-finish check §7.4 also describes is blocked, for the
reason §2 gives.

### Stage 6 — Docs

The two §7.4 blocks are fenced ` ```tuck-rejected ` today. `tools/doc_snippets`
fails the build when such a block *starts parsing*, so Stage 1 forces this
stage — the gate will not let the feature land undocumented.

---

## 2. The one thing §7.4 does not settle: the acquire surface

Everything above is built and verified. One piece is not, and it is not an
oversight — the spec does not say enough to build it.

**There is no Tuck-level way to acquire into a registry or to mark an entry
finished.** §7.4 describes what those operations DO in complete detail, and
never says how they are spelled. The nearest thing it gives is `kind::sweep`,
which uses `::` — the module-qualifier syntax, a resolution path neither
`Pool.acquire`'s nor a member call's.

Three spellings are consistent with what §7.4 writes, and they are not
equivalent:

| Spelling | Precedent | Cost |
|---|---|---|
| `udp::acquire` / `udp::finish` | §7.4's own `kind::sweep` | `::` today means "another module"; a kind is not one |
| `Udp.acquire`, mirroring `Pool.acquire` | the pool machinery §7.4 says this IS | needs kinds to be Capitalized, which §7.4's examples are not |
| an extern the library declares, the registry reached through its handle | §7.4's own `fn open(...) -> UdpSocket!` example | leaves acquire/finish outside the language |

Picking one is a language decision, not an implementation one. Guessing costs
more than waiting: every downstream stage would learn the guess, which is what
the tree's own "each construct gets its own node kind" rule is about.

**What that blocks, precisely:** §7.4's static check — "every acquire ends in
exactly one of: a defer mark, or an escape into the registry". The *escape*
arm is already sound and already enforced by construction (the registry closes
at exit, which is what makes the local analysis sufficient). The *defer mark*
arm cannot be recognised, because there is no mark to recognise. A partial
rule here would be worse than none: the obvious candidate — "an acquired
handle dropped on the spot is a leak" — fires on something §7.4 explicitly
calls sound, since a dropped handle is still in the registry and close-all
still gets it.

**What is NOT blocked, and is done:** the registry itself, its three policies,
the inline watermark sweep, LIFO close-all, the stale-handle generation bump,
the per-kind handle type, and the `OPEN RESOURCES (n)` report — which runs at
exit in a debug build and names the kind, the slot and the acquire site. The
report is the runtime half of the same question the static check asks, and it
answers it for real programs today.

## 3. Smaller boundaries

- **The acquiring fn's return type is not verified** — §0.3.
- **`on_full: error`** needs the kind to name an error enum to raise. It
  parses and reaches the declaration; the table currently treats a full capped
  kind as absence, which is §7.4's stated behaviour for the default.
- **`on_finish: flush`** likewise reaches the declaration. What `flush` MEANS
  for a kind is the `onFinish` callback its library binds, since the runtime
  cannot know: flushing a file, a socket and a TLS session are three different
  syscalls.
- **A sweeper actor** stays what §7.4 calls it — "a possible opt-in once
  actors land", never a requirement. The inline sweep needs no thread.
