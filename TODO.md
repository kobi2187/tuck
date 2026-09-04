# TODO — every known bug, gap and unfinished thing, in one place

Collated 2026-08-29. This file is an INDEX, not a replacement: each entry
says what is wrong, how confident we are, and where the full write-up lives.
Fix an entry, delete it from here and update its source.

**The suite is the authority.** `./tests/run` prints every `OPEN` line, and
`tests/suites/end_to_end.nim` checks the count in `MISSING-FEATURES.md`
against the number of `bugOpen` assertions, so those two cannot drift apart
silently. Everything else here is prose and can.

Sources collated:
`MISSING-FEATURES.md` · `stdlib-project/FRICTIONS.md` ·
`thoughts/shared/audits/stage-boundary-crossings.md` ·
`thoughts/ledgers/CONTINUITY_CLAUDE-d-backend.md` ·
`scratchpad/actor-playground/FINDINGS.md` ·
`scratchpad/iface-playground/FINDINGS.md`

Confidence key: **[repro]** reproduced by running · **[read]** read from the
code, not run · **[design]** a decision that was never made.

---

## 1. Design gaps — a decision was never made

These are not bugs. Nobody has ruled, so no implementation can be correct.

- [ ] **[repro] Full-mailbox policy is unstated, and today it deadlocks.**
  `send` is fire-and-forget and `[queue: N]` is a compile-time bound, so a
  mailbox can fill. The spec never says whether it blocks, drops or raises.
  Observed: it DROPS silently, and a `waitUntil` on the dropped work then
  spins forever. All three backends agree because D was built to match
  rather than invent a fourth behaviour. → FRICTIONS #9 (with the
  2026-08-29 update), actor-playground FINDINGS.
- [ ] **[repro] `send` without `waitUntil` never delivers.** 10 sends into a
  queue of 4 with no wait leaves the actor untouched: `main` never yields,
  so the daemon never runs. An actor program with no `waitUntil` and no task
  does nothing at all. → same sources.
- [ ] **[design] How `Seq` crosses a call boundary.** Emitted as a plain
  value in/out — no `sink`, no `var` — so an append loop is O(n²) today.
  The call-site spelling (`xs ..push {v}`) is already right either way, so
  this is a lowering decision, not an API one. → FRICTIONS #8.
- [ ] **[design] Correlation tokens for actor replies.** Decided in
  principle: the token is a payload field the CALLER generates, and the
  actor keeps a table (probably a hashtable, tracking finished values and
  pending work). Nothing implemented; no codegen change expected since the
  token rides as an ordinary parameter.
- [ ] **[design] Recursive types have no expression.** Direct
  self-containment is infinite-sized; the corpus works around it by indexing
  into a flat `Seq`. Fine in an arena world, but currently forced rather
  than chosen. Lands on `std.encoding`, `std.reflect`, ASTs, JSON.
  → FRICTIONS #4, ROADMAP "slab allocator" experiment.
- [ ] **[design] Hashing primitives.** `satisfies int: Hashable` is refused
  (correctly — `satisfies` matches declared objects), which leaves
  `Table[str, V]` with no way to hash its key. Blocks `alloc.map` and
  `alloc.set` entirely. A `fnsig` hash slot needs no language change and is
  the current front-runner. → FRICTIONS #6.

## 2. Unimplemented / partial language features

- [ ] **[repro] Generic `actor` does not parse.** Blocks a service actor
  generic over its payload. Genuinely unclear whether it SHOULD exist — an
  actor is a compile-time singleton, so "one instance, generic over T" may
  be meaningless. Wants a ruling either way; today the error reads like a
  parser gap. → FRICTIONS #2.
- [ ] **[repro] Storing into a `fnsig` slot is not signature-checked.**
  A `{a: str} -> str` fn sits in a `{x: int} -> bool` slot with no
  complaint. Calling THROUGH a slot checks arity, so the gap is specifically
  the store — which is `bake`'s whole contract. → FRICTIONS #3.
- [ ] **[read] Effect propagation is require-declared, not inferred.** The
  ruling is implicit propagation; the checker still makes you declare it.
  → MISSING-FEATURES D, ROADMAP:26.
- [ ] **[read] Typed select sources.** `on select` lowers `read <fd>` and
  `timeout <ms>` only. Dotted forms (`resp.ok`, `timeout.5s`) parse as
  opaque strings. Blocks example 16. → MISSING-FEATURES B/C.
- [ ] **[read] Numeric conversion work (ROADMAP ruling, ordered).**
  (a) enforce no-implicit-conversion at binding sites — `compatible()` in
  `typecheck.nim:263`, with the `strictKind` define already there to measure
  the blast radius; (b) implement `~`/`^` so there is a way to say yes;
  (c) implement `[wrapping]`/`[trapping]` for real, THEN switch the default.
  Only `[saturating]` has codegen today. A default naming `[trapping]` is
  theatre until trapping traps.
- [ ] **[design] Variant sets in fn signatures.** Semantics ruled
  (`ProtocolStage<Login|Active>` narrows where a fn may be called); the
  SPELLING is unsettled, since `[T]` and `[...]` are taken.

## 3. Checker bugs

- [ ] **[repro] Field access on a primitive is unchecked.** `s.wibble` on a
  `str` typechecks clean and becomes `<unknown>`.
  `typecheck.nim missingFieldMessage` declines to report when the receiver
  has no declared fields — deliberate for sum types, but it means every
  primitive receiver accepts every name. **Pinned:** `known_bugs`, bugOpen.
  Related: `len` is declared NOWHERE (not std, not any runtime) and resolves
  by luck in whichever backend spells it the same way. Declaring it needs
  the `seq`/`str` ambiguity settled and `Seq[T]` binding against `Seq[int]`
  — both hit and reverted. → MISSING-FEATURES A4.
- [ ] **[repro] A member fn shadows a top-level fn of the same name.**
  `collectSigs` registers members under their bare name in the same flat
  `fnSigs`. Attempted and reverted: members must STAY there, because
  `d.noise` resolves through `asFnByName`. Needs call resolution to
  distinguish them. **Pinned:** `member_names`. → MISSING-FEATURES A1.
- [ ] **[repro] Two statements on one line, no separator, are silently
  accepted as two statements.** `echo total`'s ORIGINAL framing ("both
  names read as `<unknown>`") is now stale — `synthVar`'s fallback
  tightening (2026-09-04) makes an undefined bare name like `echo` a hard
  error on its own. The REAL, still-open bug: `double 5` where `double` IS
  declared (takes a param) compiles clean, emitting `tuck_double` and `5`
  as two separate dropped statements — confirmed directly (`tuck c`,
  inspected the emitted Nim). Root cause identified, a fix attempted and
  reverted (2026-09-04): `parser_expr.nim`'s `parseBlock`/`parseBraceBlock`
  statement loops advance a newline if present but never REQUIRE one
  between statements, so two bare atoms on one line parse as two
  statements with nothing catching it. The naive fix — reject unless the
  next token is `tkNewline`/`tkDedent`/`tkEOF` — broke 30 real tests: a
  `tkDedent` closing an INNER block (the body of an `if`/`match`/`for`/
  `while`) is consumed inside that inner `parseBlock` call, so by the time
  control returns to the OUTER statement loop, the separator between that
  compound statement and its next SIBLING is already gone — indistinguishable,
  by token kind alone, from `double 5`'s missing separator. The real fix
  needs to compare LINE NUMBERS (only reject when the next token starts on
  the SAME line as the statement just parsed ended, not merely "no
  newline/dedent token is sitting right here") — needs the parser to know
  where the previous token's span actually ENDED, which may not currently
  be tracked; check `Parser`'s state in `parser_base.nim` before attempting
  this again. `dcPaCallSyntax` (`TK-PA04`) exists in `diagnostics.nim` but
  is never actually raised anywhere — likely meant for exactly this family
  but never wired up; reuse it (or add a fresh code just past
  `dcPaEmptyBlock`/`TK-PA09`) once the line-comparison version is built.
- [ ] **[repro] By-type payload matching does not run for MEMBER calls.**
  `{n: 7, text: "x"} b.grow` against `grow({self, count: int, label: str})`
  checks OK and then drops the payload entirely. `payloadFields` reports
  `shapeKnown=false` for a member call, so the claim passes never run. The
  same payload against a top-level fn works. → audit F6.
- [ ] **[repro] `declForType` is never recorded for inferred types.**
  `resolveTypeNames` walks only types the user WROTE, so a type the checker
  synthesized for an expression has no declaration edge and every consumer
  re-derives it by name — a decl-list scan per node, which is why emit is
  quadratic. A partial fix landed (`resolveInferredTypes`); it does not
  reach these nodes, which arrive with `id=unset`. → audit F1.
- [ ] **[repro] `callParamsFor` unrecorded for three categories** — pending
  fns, distinct-type ctors, combinators. Every backend therefore keeps a
  decl-scan fallback (~150 lines across three). Members were fixed
  2026-08-27; these three remain. → audit F2.

## 4. Compiler-internal issues (not user-visible)

- [ ] **[repro] Emit is quadratic in every backend.** D's share of a compile
  went 0.03s / 0.11s / 0.38s at 200 / 500 / 1000 types — doubling n
  roughly quadruples it. Nim has the same curve with a smaller constant.
  Cause is the decl-list scans above, not the emitters. → audit, SCORES.md.
- [ ] **[read] `decl_index.nim` may be the wrong fix.** It makes emit-time
  re-derivation cheap instead of removing it; measured gain was 0.84s →
  0.80s. If F1/F2 land and the scans disappear, DELETE it rather than keep a
  cache for work that no longer happens. → audit F4.
- [ ] **[read] Marker plumbing is partly duplicated.** Two name→marker maps
  remain (`parser.nim:123`, `parser_type.nim:199`). The two marker→name maps
  were collapsed into `ast.effectName` on 2026-08-29 — they had DRIFTED, both
  deriving the name from the enum and dropping the underscore, so
  `[may_block]` printed as `[mayblock]`. → MISSING-FEATURES D.
- [ ] **[read] One C implementation of the runtime.** Nim, Odin and D
  runtimes are mirrored BY HAND and have drifted repeatedly. Collapsing the
  offload seam into one C file bound over the existing FFI removes the
  class of bug. The coroutine engine already works this way (all three
  drive the same vendored minicoro), which is the precedent.
- [ ] **[read] Stage boundaries leak.** 90 emit-time queries across the
  three backends re-derive facts an earlier stage should have recorded.
  Rule: a question asked at emit means an earlier stage did not finish.
  → the whole audit document.
- [ ] **[read] `lowerExpr`'s children-recursion order is per-pass, not a
  rule.** `lowering.nim`: `flattenRegistryRaise` now runs BEFORE the
  `for c in e.children: lowerExpr(c, m)` loop (moved there to fix the
  `SystemEvents.raise` double-call bug this session); `flattenMemberCallPayload`/
  `explodePayload` still run AFTER it, because they need already-lowered
  children. The ordering is correct today only because I hand-traced one
  bug into it — nothing enforces a new pass picks the right side. A wrong
  side silently corrupts the AST (no compile error), which is exactly what
  happened before the fix. Needs either a comment convention every future
  pass must read, or (better) `PipelineStage`/`requireOrder` from the
  saved CLI/pipeline plan turned into an actual per-pass ordering check.
- [ ] **[read] No real "indexing" stage — two `buildDeclIndex`s, same
  name, different shape.** `compiler/decl_index.nim`'s `DeclIndex` is
  built lazily per backend, on demand, at codegen time; `codegen.nim` has
  a SECOND, differently-shaped proc also named `buildDeclIndex` for its
  own use. Nothing checks the two agree. Neither is a whole-program gate
  anything else waits on, despite reading like one.
- [ ] **[read] `checkOrDie`'s typecheck→verify-effects ordering is
  enforced only by a comment.** Typechecking resets the shared `semLayer`
  side-table; `verifyModuleEffects` must run after or async call-site
  marks are wiped before codegen reads them. No assertion catches a
  future reordering. Saved plan's Phase 2 (`PipelineStage` enum +
  `requireOrder`, `--verify-stages` opt-in) targets this directly —
  drafted, not applied.

## 5. Backend bugs

### Nim
- [ ] **[repro] Invariants cannot be kept in a release build.** See §2.
- [ ] **[repro] An actor handler containing a registry raise emits nothing
  usable** — no proc for the handler at all (example 20). Same source fails
  in D differently, so the cause is upstream of both.

### Odin
- [ ] **[repro] A list literal cannot reach a `Seq` parameter.**
  `[dynamic]T` has no literal form. Needs statement hoisting in the emitter.
  **Pinned:** `interface_seq`. → MISSING-FEATURES A2.
### D
- [ ] **[read] Registers are not `volatile`.** D has no volatile qualifier;
  `core.volatile`'s load/store are the supported spelling. Correct for the
  examples, wrong for a real embedded target.
### Cross-backend
- [ ] **[repro] The Nim backend is stricter than D on numeric mixing.**
  `acc + payload.value` with `acc: int` and the field `u16` compiles in D
  and fails in Nim. Same source, two answers about which programs exist.
  The numeric-conversion ruling closes this; until then it is a portability
  hole. → ledger.

## 6. Diagnostics — right refusal, wrong message

A cluster with one shape: the compiler is correct to refuse, but the message
describes the parser's or backend's problem rather than the author's.
FRICTIONS calls #7 the house standard — it names the type, the rule, the
position, and a way forward.

- [ ] **16-actor-tasks-unified-syntax** — fails the CHECKER, not codegen:
  `.fn {args}` on an undeclared method (the example needs a `pending:`
  stub), plus dotted select sources. → MISSING-FEATURES B.
- [ ] **20-embedded-mp3-player** — see the Nim and D entries above.

## 8. Object member receivers alias — undecided, needs a ruling

Found 2026-08-29 while probing the stateful-value question. NOT fixed: the
resolution is a language decision, not a codegen one, and it was left open.

**The facts, all reproduced by building and running:**

- Chains are CORRECT and uniform. `c ..bump` emits `c = bump(c)` in every
  backend — return-value assignment, no aliasing. `checkMutatorCall`
  (`typecheck.nim:1188`) enforces the contract: a `..` mutator must return the
  receiver's type. Records prove the whole path: `let b = a ..withPort {p:8080}`
  leaves `a` at 1 and gives `b` 8080.
- The DIRECT call has no such contract. `{self: c} bump` emits `bump(c)` with
  `self: var Counter` (`codegen.nim:1315`, unconditional — no body analysis
  exists anywhere in the compiler). The member mutates the CALLER's object.
  `let r = c.bump` gives `r.n=1` AND `c.n=1`; value semantics says `c.n=0`.
- A READ-ONLY member cannot be called on a parameter. `p.sum` where `sum`
  mutates nothing fails in Nim with `expression 'p' is immutable, not 'var'`.
  Legal Tuck, rejected in the backend's words. Works on a local, because Nim's
  `var T` binds any addressable location — which is why every existing test
  misses it (they all use locals).
- **The three backends disagree.** Nim: `var self`, aliases. D: `ref self`,
  aliases, and `tests/suites/d_backend.nim:185` RUNS a program asserting the
  receiver mutates across two direct calls (expects 9). Odin: declares `^T`
  but its call sites never pass an address — its own comment says
  `# ponytail: call sites don't take the address yet`.
- `value_semantics.nim:383` is the only Nim-side coverage and is `okCheck` —
  typechecks a member that mutates `self`, never calls it. That is how this
  survived.

**The ruling needed:** are function arguments copied, `self` included?
- If YES (`self` is an argument like any other): `var self` dies in all three
  backends, the read-only-on-param defect and Odin's unwired call sites both
  fall out for free, `d_backend.nim:185` is asserting the wrong thing and gets
  rewritten to the chain form, and a member that writes `self` but does not
  return the object type becomes a silent no-op — example 04's
  `fn play({episode: Episode}) -> void` is exactly that shape, and probably
  wants rejecting the way `checkMutatorCall` already rejects it for chains.
- If NO (object members are the language's one aliasing construct): it needs
  saying in the spec, `let c` is genuinely unsafe through a member call, and
  the read-only-on-param defect needs the body analysis that does not exist
  in order to emit a plain `self` for non-mutating members.

Related and separate: `{self: Self}` declares but cannot be CALLED —
`argument to 'louder' expects Self but got Player`. `Self` is substituted in
five places (`typecheck.nim:529/532`, both backends, conformance) but not on
the call path. `value_semantics.nim:391` uses this exact shape and only
`okCheck`s it.

## 9. Backlog — raised in conversation, not yet started

- [ ] **Actor threading model.** Today all actors AND tasks share one
  cooperative scheduler on one OS thread (spec §9.4) — no preemption, an
  actor with a slow handler blocks everything else. User's proposal
  (2026-09-01): thread-per-actor (or a small pool), since actors are
  singleton services, few per program (user's estimate: <10), and already
  safe by value semantics (a message is copied into the mailbox before
  crossing — spec-guaranteed, verified by existing tests: "a record sent
  to an actor is copied into the mailbox"). Two concrete gaps identified
  as needing solving, not yet designed:
  1. **`waitUntil`'s public-field polling has zero synchronization.**
     Reads a field directly, safe only because nothing is ever actually
     concurrent today. Needs either atomics/a lock/seqlock-style
     versioning on every actor field read, or a spec-level move to
     message-based state exposure instead of direct-field polling.
  2. **The mailbox is deliberately lock-free BECAUSE nothing is
     concurrent** — `Mailbox.enqueue`/`dequeue` in all three runtimes are
     explicitly documented as lock-free "since the scheduler is
     cooperative on ONE thread — sends and drains never interleave."
     Thread-per-actor makes every `send` a genuine MPSC produce against
     the actor's own consumer thread.
  User's proposed direction for both: a lock-free MPSC ring for the
  mailbox, plus a mutex around public actor fields. Assessed as sound and
  buildable (concrete primitives exist in all three backends: `std/
  atomics` in Nim, `core:sync`/atomic ops in Odin, `core.atomic` in D) —
  no exotic new mechanism needed. NOT designed or started: needs a real
  design pass (thread-per-actor vs. a pool, exact synchronization
  primitive per backend, and reconciling with the project's own
  portable-runtime-characteristics rule — Nim's ARC across threads,
  Odin's GC-free threads and D's GC-aware threads are three different
  starting points for "make this safe," a bigger lift than the current
  single-thread model was specifically chosen to dodge).
- [ ] **Coroutine starvation: no preemption for a CPU-bound loop.**
  Related to the actor-threading item above but a separate concern — even
  with the current single-thread cooperative scheduler kept as-is, a `for`/
  `while` loop (or a long call chain) that never crosses an `[io]` boundary
  never yields, and starves every other actor/task sharing that one thread.
  Spec §9.4's "no preemption" is a deliberate simplification with this
  exact known risk, not yet hit by any example/test.
  User's proposal (2026-09-01): a per-coroutine budget counter,
  decremented at safepoints, forcing a yield at zero — a counter instead
  of a monotonic-clock read, since the syscall cost of the latter would
  dwarf the check itself. Design settled in discussion, NOT implemented:
  - **Where to decrement**: UNCONDITIONALLY, at every loop back-edge
    (`for`/`while`) and every user-function call, in every function,
    everywhere — no reachability analysis. User's own call after hearing
    the alternative: "prefer the simplistic unconditional insertion at
    every fn and loop back-edge." Cost is one decrement + one branch per
    iteration/call, negligible next to real loop-body work in any
    realistic program.
  - **Reachability analysis is NOT needed for correctness**, only as an
    optional later optimization to SKIP inserting the check in code
    provably never scheduled cooperatively. If ever pursued: the correct
    root set is {every `dkActor` handler body, every `dkTask` body, `fn
    main`} — NOT "reachable from an `[io]`-marked function" as originally
    framed. `[io]` marks an async YIELD BOUNDARY (already lowered
    automatically today); it says nothing about which call graph actually
    executes on a coroutine. A plain, never-`[io]` helper called deep
    inside a task's call graph needs the safepoint exactly as much as an
    `[io]` one does.
  - **Mechanism should just work with minicoro**: it is a stackful
    coroutine library, so a mid-loop yield-and-resume needs no state-
    machine transform — the loop's locals live on the coroutine's own
    stack across the yield. NOT verified this session; confirm before
    building (check `compiler/tuck_coro.nim` / the vendored minicoro
    source for the actual yield/resume call shape).
  Touches lowering + all three backends' loop/call emission if built —
  scoped as a real feature, not a quick patch. No known failing case
  yet; logged for when one appears, or when actor threading (above) makes
  this more urgent by putting more independent work on fewer schedulers.
- [ ] **Registry: multiple handlers per event (C#-delegate-style).**
  Confirmed live (2026-09-01, chasing the registry-raise bug above): a
  second `on Registry.Event(...):` for the SAME event is rejected today
  purely because a handler is an ordinary top-level `fn` named
  `"Registry.Event"`, colliding with Tuck's general "every top-level name
  is declared once" rule — not a deliberate one-handler-per-event design
  (no diagnostic code exists for "duplicate handler," only `dcRgDuplicate`
  for "more than one registry in a program", a different rule). The
  registry itself is already a WHOLE-PROGRAM concept, not per-module:
  `checkRegistry` takes every loaded module in the import closure
  (`collectRegistries`/`collectHandlers` both scan all of `mods`), so a
  registry in one module and a handler in another already works today —
  confirmed by reading `checkRegistry`'s signature and callers, not
  assumed.
  `genRegistry`'s codegen (`compiler/codegen.nim`) ALREADY fans out to
  every matching handler: `for decl in ctx.module.decls: if decl.kind ==
  dkFn and decl.name == handlerName: handlerCalls.add(...)` — a LOOP,
  not an assignment — so if two decls named `"Registry.Event"` could
  coexist, both would already be invoked, in whatever order
  `ctx.module.decls` iterates them. NOT designed: the naming scheme that
  would let multiple handlers coexist (an ordered list of handler decls
  under one event, not one uniquely-named decl per event), ORDERING
  semantics user flagged as unclear (declaration order within a file is
  one candidate; cross-module ordering is genuinely ambiguous and would
  need a real ruling, not an assumption), and a way to REPORT every
  handler's declared location (user's ask) — possibly an extension of
  `tuck dump` (the existing `--stage` dump machinery) rather than a new
  command, not investigated. Odin/D's own registry codegen
  (`codegen_odin.nim`'s registry section) was not checked for the same
  fan-out behavior Nim's `genRegistry` has — verify it mirrors this
  before assuming the fix is codegen-symmetric across backends.
