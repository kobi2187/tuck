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

### 0.6 Where does a resource's PROTOCOL live?

A file has two states and the registry tracks both. A database connection has
`Open → InTransaction → Closed`, and that is the library's to define. So a kind
may have a protocol beyond live/finished — and the question is who writes the
type it becomes.

**Settled (ruled 2026-09-14): the kind NAMES a sealed sum type; the library
declares that type, and the compiler still supplies the handle.**

```tuck
# the LIBRARY — it knows what a db connection can do
type DbState:
  | Open
  | InTransaction
  | Closed
  transitions:
    Open          -> InTransaction
    InTransaction -> Open
    Open          -> Closed
    InTransaction -> Closed
```

```tuck
# the resources block — it knows how many, and how they close
resources:
  file [cap: 8, on_finish: flush]      # no protocol — unchanged, zero ceremony
  db   [cap: 4096, states: DbState]
```

**The two halves are decoupled because they have different owners.** A
`resources:` block is a deployment decision — which tables exist, how large,
which policy — and a library cannot answer it: it knows `db` has three states,
not that this box wants 4096 connections. The protocol is the reverse: the
library that wraps the OS service knows the edges, and no app should restate
them, because an app that *can* restate them can restate them differently.
Writing the states inside the kind welds the two together and forces one owner
on both.

Three shapes were on the table. The first two make the LIBRARY write the
envelope and then check it:

| | Problem |
|---|---|
| `db [states: DbState]` — the kind names a library-written type | the library can write a malformed envelope, so a conformance check is needed, and any concrete shape rule is wrong for some library (a TLS session has two handles; a db holds one in several variants) |
| grow `group` to constrain shape | §5.5 ties `group` and `interface` to the *identical requirement-list grammar* — both are lists of required **functions**. Adding variant templates makes one keyword two unrelated things, which is the "clever reuse costs more later" invariant. And a general mechanism built for one caller is speculative |

The envelope objection is what `states:` dodges, and it is worth being precise
about why, since naming a type looks like the first row: **the library writes
only the STATES, never the handle.** A bare sum type with transitions is an
ordinary §4.4 declaration that the compiler already validates — there is no
shape to get right, no field to omit, no second handle layout to keep in step.
The compiler still generates `<Kind>Handle`, so §0.3's "you cannot fail to
conform to a type you did not write" holds exactly where it mattered.

**It costs the REGISTRY nothing.** The emitted handle stays `ResourceHandle`,
the table is unchanged, and no backend learns anything about states — adding
`states:` to a kind moves no emitted line but the acquire-site numbers that
shifted. The state type itself emits as an ordinary sum type, because that is
exactly what it is; the decoupling buys the protocol a normal declaration
instead of a special one.

**Two things are DERIVED, so they cannot be declared wrong:**

- **initial** = the first state, §4.4's existing convention. `acquire` starts there.
- **terminal** = the state with no outgoing edge. `finish` leaves the handle there.

What is left to check is that the machine is well formed, and the rules are the
ones a *resource* protocol needs rather than generic graph hygiene:

| Rule | Code |
|---|---|
| `states:` names a sum type, and one carrying edges | TK-RS10 |
| every edge endpoint names a state of that type | TK-RS06 |
| exactly one terminal — too many and several look final; none and the protocol never ends | TK-RS07 |
| every state reachable from the initial one (the rule `[sealed]` already follows) | TK-RS08 |
| **the terminal reachable from every state — you can always close** | TK-RS09 |

That last one is the one that earns the feature: a live cycle with no exit is a
handle that cannot be closed from where it is, which is a leak the declaration
promised to prevent.

### 0.8 Who declares the kind, and what each side still cannot do

With `states:` decoupled, the protocol is written once by whoever owns the
resource and named by whoever needs a table. What remains is the KIND itself —
its name, its cap, its policy — and that is not yet split the same way.

Today a kind is declared **exactly once** program-wide (TK-RS02), so its
declaration site owns every knob on it. Both arrangements work, and they trade
differently:

```tuck
# dblib.tuck — the library declares the type AND the kind
type DbState:
  | Open
  | Closed
  transitions:
    Open -> Closed

resources:
  db [cap: 32, states: DbState]

fn connect({fd: int}) -> ?DbHandle [resource: db]:
  return acquire fd, db
```

The app then imports `dblib`, declares nothing, and `finish h.value, db`
resolves — verified end to end in `tests/suites/resources.nim`. The cost is
that `cap: 32` is the library's guess about a deployment it cannot see.

The other arrangement — the app writing `resources: db [cap: 4096, states:
DbState]` while the library only uses the kind — **typechecks but does not
link**, and the reason is worth writing down rather than discovering twice:
`<Kind>Handle` and `tuckRes_<kind>` are emitted into the module that declares
the kind. If that is the app, then `dblib`'s own `connect` — which returns
`?DbHandle` and calls `acquire(tuckRes_db, ...)` — references symbols in a
module that imports *it*. Nim reports `undeclared identifier: 'DbHandle'`, and
Odin and D have the same cycle for the same reason.

So the real constraint is an EMISSION one, not a language one: **a kind's table
must live somewhere every user of it can see.** Two ways out, neither built:

| | |
|---|---|
| **Split the declaration** — the library declares `db [states: DbState]`, the app re-opens it for `[cap: 4096]` | Keeps the table in the library module, so nothing moves. Needs a merge rule in place of TK-RS02's blanket refusal: the protocol declared exactly once, and *each knob* set at most once — no last-writer-wins, no import-order dependence, and the diagnostic can name both sites |
| **Emit the tables into one shared unit** every module imports | Matches what §7.4 describes — a global per-kind table — and lets the app own the whole block. Costs a new generated output in all three backends, plus import and link ordering |

The first is a checker change; the second is an architecture change that makes
the app the sole owner. Recorded here as a ruling, not as work in progress.

### 0.7 Why the protocol is validated but not yet TRACKED

`acquire` starts at the initial state and `finish` leaves at the terminal one,
but the checker does not yet narrow a handle *through* the machine — because
there is no way to walk an edge. §4.4b changes a tracked variant by
reassignment, and a handle is `{slot, gen}` with the state erased, so there is
nothing to assign. A state change is a library OPERATION (`begin`, `commit`),
so the walking surface belongs on those fns, and that is a further ruling.

Until it lands, the protocol is a well-formedness contract on the declaration:
it makes libraries look alike and rejects a machine that could never work.

**The soundness question, answered.** When tracking does land it will NOT need
single-owner handles, though an earlier reading of this document said it would.
Under a copy, both bindings narrow independently, so a stale `finish` is a
MISSED error rather than a false rejection — the permissive direction — and the
registry's generation check catches it at runtime. §7.4 architects for exactly
that: "escape is always sound — the registry guarantees close-at-exit — so no
whole-program alias analysis is needed; the global table is the safety net that
makes the local analysis sufficient." Single-owner would make the check
*complete*; §7.4 says completeness is not required.

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

## 2. The registry surface — `acquire` and `finish`

§7.4 describes what acquire and finish DO in complete detail and never says how
they are spelled. The nearest thing it gives is `kind::sweep`, which uses `::`
— the module-qualifier syntax, a resolution path neither `Pool.acquire`'s nor a
member call's.

**Ruled (2026-09-14): a symmetric pair of statements, each naming its kind.**

```tuck
resources:
  udp [cap: 64, on_finish: shutdown]

pending:
  fn rawOpenUdp({port: u16}) -> int [io]

fn openUdp({port: u16}) -> ?UdpHandle [io, resource: udp]:
  return acquire {port: port} rawOpenUdp, udp     # register; yields ?UdpHandle

fn serve({port: u16}) -> int [io, resource: udp]:
  let sock = {port: port} openUdp
  if sock.ok:
    defer:
      finish sock.value, udp                      # release intent
    return 1
  return 0
```

|  | operand | yields |
|---|---|---|
| `acquire <raw>, <kind>` | the RAW OS handle an extern produced — a number | `?<Kind>Handle` |
| `finish <handle>, <kind>` | the kind's own handle type | nothing |

**One parser builds both** (`parser_expr.parseResourceOp`). Same keyword
position, same operand order, same trailing kind name — symmetric by
construction rather than by discipline, and the two cannot drift apart because
there is nowhere for them to drift.

Both are contextual, recognised by spelling and gated on what follows, exactly
as `parser.contextualDecl` handles the top-level openers the lexer does not
tokenize. The expression-level twin is `parser_expr.contextualStmt`. The gate
is a NAME or `{` following: Tuck calls are postfix (`{payload} fn`), so two
bare identifiers in a row are not an expression in any other construct, and a
variable named `acquire` or `finish` still reads as one.

### Why the kind is named on both

On `acquire` the kind is not redundant at all — a raw fd says nothing about
which table it belongs in, so the statement could not work without it. On
`finish` it IS redundant: the handle's type already determines the table. It is
named anyway, and checked:

- **A release is read far more often than it is written.** The reader should
  not have to find the declaration of `sock` to learn which registry this
  touches.
- **The redundancy is CHECKED, never trusted.** `finish sock, file` on a
  `UdpHandle` is TK-RS04, by name, at compile time.
- **It costs nothing at runtime.** The kind names the table directly, so the
  emitted call is `finish(tuckRes_udp, sock)` — no dispatch, and no table id
  riding on the handle, which stays `{slot: int32, gen: uint32}`.

That asymmetry in the ARGUMENT is what makes the symmetry in the FORM worth
having: the pair reads the same way, so the redundant half is free to be
redundant.

### What the pair buys

**The raw fd never reaches Tuck code.** It exists between the extern's return
and the `acquire`, and nowhere else. Everything downstream holds a
`<Kind>Handle`, whose tenancy check makes a stale use a caught error rather
than a write to the wrong socket.

**The table is written where it is declared.** This was the blocker the pair
dissolves: an extern's *implementation* lives in the runtime, which cannot see
`tuckRes_udp` — that symbol is emitted into the user's module. With `acquire`
as a statement, registration happens in Tuck, in the module that has the table
in scope. No plumbing, no codegen magic.

**The acquire SITE is free.** The compiler fills it from the span
(`resolution.acquireSite`), so the OPEN RESOURCES report can say *where* a
leaked handle came from without the author writing a site that would go stale
the first time a line moved.

### Rules, and where each lives

| Rule | Code | Where | Why there |
|---|---|---|---|
| the named kind is declared | TK-RS01 | `typecheck_resources`, whole-program | kinds are an open set; a module may acquire into a kind an import declared |
| `finish`'s kind matches the handle | TK-RS04 | `synthFinish`, per module | needs a synthesized type |
| `acquire`'s operand is a raw number | TK-RS05 | `synthAcquire`, per module | same; acquiring a `<Kind>Handle` would register one handle twice |

`synthFinish` reads the RAW synthesized type, never a `resolve`d one:
resolving follows a named type to its body, and every kind's handle is the same
empty record — so a resolved `UdpHandle` and a resolved `FileHandle` are
indistinguishable, which is exactly the distinction being checked.

Exhaustion stays ABSENCE, so `acquire` yields `?<Kind>Handle` and the existing
optional discipline applies unchanged: reading `.value` without a guard is the
ordinary unhandled-optional error, not a resource-specific one. A kind
declaring `on_full: error` aborts instead of returning, but the TYPE is the
same — policy does not change shape.

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
