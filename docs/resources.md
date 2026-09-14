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

### 0.5 Does every combination of a kind's attributes make sense?

**No — and the incoherent ones are rejected, not left to do nothing quietly.**

The knobs constrain each other, so the COMBINATION is the declaration rather
than a menu to pick from freely. §7.4's examples are illustrating *syntax*;
they are not asserting that every pairing they happen to show is meaningful.

The line drawn is between **permanently incoherent** and **merely inert
today**, and only the first gets a rule:

| Combination | Verdict | Why |
|---|---|---|
| `on_full` without `cap` | rejected | an unbounded table never fills. No reading of §7.4 makes this apply |
| `sweep_batch` without `policy: lazy` | rejected | it sizes the watermark sweep, and lazy is the only policy that runs one. Under `strict` the mark reclaims one entry immediately; under `exit` nothing reclaims until close-all closes everything. No batch, either way |
| `policy: lazy` without `cap` | **allowed** | inert in this implementation — the watermark is a fraction of the cap, so it never trips — but §7.4 names two other triggers for the same sweep, "on memory pressure, or at cap", and memory pressure needs no cap. A trigger not yet built is not a combination that could never work |

**This reverses an earlier call, and the reason is worth recording.** The
`sweep_batch` rule was written, found to reject §7.4's own example
(`net [cap: 10_000, on_full: error, sweep_batch: 100]` in a block declaring no
policy, so `strict` by default), and deleted on the grounds that "the spec is
the authority on its own examples".

That was wrong twice. The example is a *syntax* illustration, so it was never
claiming that pairing was meaningful. And `README.md`'s trust order puts
**the compiler above `tuck-spec.md`** — so an example that contradicts a
sound rule is the example to amend, which is what happened: §7.4's block now
reads `net [cap: 10_000, policy: lazy, ...]`, which is both illustrative and
coherent, and says so in a line beneath it.

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

## 2. The release surface — `finish <handle>, <kind>`

§7.4 describes what acquire and finish DO in complete detail and never says
how they are spelled. The nearest thing it gives is `kind::sweep`, which uses
`::` — the module-qualifier syntax, a resolution path neither `Pool.acquire`'s
nor a member call's. Three spellings were consistent with it, and they are not
equivalent.

**Ruled (2026-09-14): `finish sock, udp` — the kind is named, and checked.**

```tuck
fn serve({port: u16}) -> int [io, resource: udp]:
  let sock = {port: port} openUdp     # -> UdpHandle
  defer:
    finish sock, udp
  ...
```

The handle's TYPE already decides which table is touched — every kind gets its
own nominal `<Kind>Handle` (§0.3) — so `udp` is redundant. That is the point,
not an oversight:

- **A release is read far more often than it is written.** The reader should
  not have to find the declaration of `sock` to learn which registry this
  statement touches.
- **The redundancy is CHECKED, never trusted.** `finish sock, file` on a
  `UdpHandle` is TK-RS04, by name, at compile time. A second source of truth
  that is verified is a reader aid; one that is trusted is a bug waiting.
- **It costs nothing at runtime.** The kind names the table directly, so the
  emitted call is `finish(tuckRes_udp, sock)` — no dispatch, and no table id
  riding on the handle, which stays `{slot: int32, gen: uint32}`.

Honestly: this is the more ROBUST form, not the more flexible one. The
type-based `finish sock` expresses everything this does with less ceremony;
the one thing it could not express is finishing a handle held in a generic
type parameter, which nothing needs yet. The argument that decided it is
legibility at the call site plus a compile-time cross-check, not expressive
power.

`finish` is contextual, like `defer` and `resources`: it is gated on a NAME
following, because Tuck calls are postfix (`{payload} fn`) and two bare
identifiers in a row are not an expression in any other construct — so an
ordinary variable named `finish` still reads as one.

Two rules, deliberately in two places:

| Rule | Where | Why |
|---|---|---|
| the named kind is DECLARED (TK-RS01) | `typecheck_resources`, whole-program | kinds are an open set; a module may finish into a kind an import declared, so no single module's view can answer it |
| the named kind MATCHES the handle (TK-RS04) | `synthFinish`, per module | needs a synthesized type, which the whole-program pass does not have |

`synthFinish` reads the RAW synthesized type, never a `resolve`d one:
resolving follows a named type to its body, and every kind's handle is the
same empty record — so a resolved `UdpHandle` and a resolved `FileHandle` are
indistinguishable, which is exactly the distinction being checked.

### What is still missing: ACQUIRE

`finish` is spelled; `acquire` is not. A library reaches the registry through
an extern whose implementation registers the entry, which means the extern
needs the table — and the table is emitted into the USER's module, not the
runtime. Closing that is the next ruling, and it is the last one §7.4 needs.

This also still blocks §7.4's static acquire-must-finish check, though less
than before: the *defer mark* arm now has a mark to recognise, so the analysis
is writable the moment acquire has a shape to match on.

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
