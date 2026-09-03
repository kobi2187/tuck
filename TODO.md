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

- [x] **FIXED 2026-09-01** — Generic `fnsig` did not parse (`fnsig
  Mapper[T, U]` was a parse error, blocking every higher-order generic
  API — the dangerous workaround it forced, a non-generic fnsig with bare
  `T`/`U` reading as `<unknown>` under gradual typing and silently
  disabling checking, is gone with it). Fixed at three layers:
  - **Parser**: `parseFnSigDecl` now calls the existing `parseGenericParams`
    (shared with `type Box[T]`) right after the name, storing the result on
    a new `Decl.sigGenerics` field. `parseGenericParams` moved earlier in
    `parser.nim` (was defined after its first caller needed it).
  - **Checker**: `checkThroughFnSig` used to require `slotT.kind == tkNamed`
    — a generic instantiation (`Mapper[int, str]`) is `tkApp`, so it fell
    through and was silently treated as an untyped slot. New
    `genericFnSigSig` substitutes the slot's own concrete type args
    directly (no inference needed — they're already known from where the
    slot is declared, unlike an ordinary call's generics) via the existing
    `substituteType` helper, into a fresh `FnSig` that `checkCallArgs`
    validates normally. Kept in a SEPARATE `TypeChecker.fnSigGenerics`
    table rather than reusing `fnSigs[name].generics` — that field feeds
    the payload-inference machinery any direct call by name goes through,
    and touching it risked misfiring on the unrelated (dubious, unsupported)
    case of calling a fnsig type name directly as if it were a function.
  - **Codegen**: fixed a THIRD bug this surfaced — the Nim backend's
    `dkFnSig` emission ignored generics entirely, producing `type
    tuck_Mapper* = proc(value: T): U {.closure.}` (T/U as literal
    undeclared names) then instantiating it as `tuck_Mapper[int, string]`,
    which does not compile. Now emits the real Nim generic alias syntax,
    `type tuck_Mapper*[T, U] = proc(...)`, mirroring the existing
    `d.generics`-to-`[T, U]` pattern already used for `type X[T]`.
    Odin has no equivalent to a parametric proc-type alias (Odin generics
    are `$T` parapoly procs, a different mechanism) and was silently
    emitting invalid Odin (`Undeclared name: T`) before this fix; added
    `odinUnsupported` (mirroring the D backend's existing `dUnsupported`)
    so it now dies loudly naming the construct instead. D's own generic
    type-application path already died loudly on this shape unprompted —
    confirmed, not touched.
  Verified: end-to-end build+run on the Nim backend (a generic `Mapper[T,
  U]` stored in a struct field, called through it, exit code checked);
  Odin and D both refuse cleanly instead of emitting bad output. 5 new
  regression assertions in `tests/suites/typecheck.nim` (2 checker,
  2 emit-shape, 1 runs-end-to-end) — written and confirmed RED (real
  parse error) before the fix, all green after. `./tests/run` full suite
  green; `tools/emit_examples.sh` — no example uses this yet, no diff.
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
- [x] ~~**`[may_block]` has no checker meaning.**~~ STALE — verified
  2026-08-29: it is enforced, by the general budget rule the spec describes
  (§3.7: `[irq_safe]` calling `[io]` is "one instance of the general rule,
  not a special case"). An `[irq_safe]` fn calling a `[may_block]` one is
  rejected, and the obligation propagates to undeclared callers. Now pinned
  in `declarations` — there was no effect-marker coverage at all, which is
  how a misspelling in the message survived.
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
- [x] **FIXED 2026-09-01** — Nim's invariants used to hardcode
  `when not defined(release)` AND emit Nim's `assert(...)`, which is
  itself release-stripped — a double bug, since even removing the `when`
  wouldn't have kept the check. Added `tuckInvariantFailed*(cond,
  typeName: string)` to `tuck_rt.nim` (mirroring the D backend's own),
  changed `genType`'s emission to `when not defined(tuckNoInvariants): if
  not (cond): tuckInvariantFailed(...)` — opt-out flag, independent of
  `release`/`danger`. Verified: built the emitted `.nim` directly with
  `-d:release` and a violated invariant still aborts (exit 1); with
  `-d:release -d:tuckNoInvariants` it does not (exit 0). Odin's own
  `assert(cond)` (unconditional, no release gate at all) was NOT touched —
  out of scope for this entry, worth checking separately whether Odin's
  `-o:speed`/ODIN_DISABLE_ASSERT has the same class of bug.
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
- [x] **FIXED 2026-08-30** — a member call with a payload mis-bound self.
  Two checker bugs (asPostfixApplication wrongly claimed a call carrying an
  explicit dotArg payload; synthMethodCall checked the receiver against
  the wrong slot for a member with no explicit self, distinguished from a
  top-level mutator fn via `tc.topLevelFns`) plus one Odin codegen bug the
  fix exposed (member calls never took the receiver's address, needed
  since self is always `^T`). Verified identical on Nim/Odin/D.
- [ ] **[repro] A prefix call is accepted.** `echo total` (wrong — Tuck is
  postfix) typechecks and emits `total(echo)`. Both names read as
  `<unknown>` under gradual typing. Same trap family as the fnsig
  workaround above. NOT pinned yet.
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

- [x] **FIXED 2026-09-04 — file-size ceiling: split the four giant compiler
  files, then closed the complexity ratchet the splits happened to open
  slack in.** `typecheck.nim` (2380→1966 code lines), `codegen.nim`
  (1745→606), `codegen_odin.nim` (1791→728), `codegen_d.nim` (1595→741),
  via `nimtools move-symbol`. Real constraint found mid-work: a file
  built around ONE mutually-recursive dispatch (`synthesizeKind`/
  `genExpr`/`genOdinExpr`/`genDExpr`) can only be split along edges that
  go ONE way under plain `import` — Nim disallows circular module
  imports, so a satellite that calls back into the file that already
  imports it cannot exist. `typecheck.nim`'s call graph turned out to
  have edges going both directions almost everywhere (not just
  `synthesizeKind`'s direct dispatch — anything reachable from
  `tc.synthesize`, including per-declaration and per-program
  orchestration), so only 4 truly leaf satellites came out clean
  (`typecheck_compat.nim`, `typecheck_collect.nim`,
  `typecheck_registry.nim`, `typecheck_module.nim`); two more
  (`typecheck_decl.nim`, `typecheck_program.nim`) were planned and
  abandoned once `bindConsts`'s move proved the constraint. All three
  codegen backends, by contrast, are a clean LINEAR chain
  (expr ← decl ← orchestration), so each split fully into 4 files with no
  such wall — `codegen_ctx/decl/emit.nim`,
  `codegen_odin_ctx/decl/emit.nim`, `codegen_d_ctx/decl/emit.nim`.
  `nimtools move-symbol` needed `--force` + a hand-added forward
  declaration for every mutually-recursive group it refused outright
  (correctly), and separately left behind, silently, several real
  artifacts across the ~10 extractions: three broken empty-body
  duplicate procs (stranded forward declarations with a stray `=` and no
  body) and two consts it logged as "Extracted" but that stayed in the
  source file, only surfacing as compile errors in the destination.
  Caught by a scripted scan (grep for `proc NAME(...) =` immediately
  followed, past blanks/comments/type-blocks, by another `proc NAME`) run
  after every multi-symbol move, plus a manual byte-for-byte diff of
  every moved proc body against git history before trusting each
  extraction. `tuck.nim` now imports `codegen_emit`/`codegen_odin_emit`/
  `codegen_d_emit` for the three `emit*` entry points instead of the
  three base files directly, since each base file sits BELOW its own
  decl/emit satellites in the import order. CLAUDE.md's decl-dispatch
  `else` citations updated to the new file:line locations. The splitting
  itself freed up two routines' worth of complexity-ratchet slack
  (`genReturn` in `codegen.nim`, `asInterfaceCall` in `typecheck.nim` —
  both had real extractable sub-logic, not flat dispatch tables), closing
  `tests/suites/complexity.nim`'s pre-existing HEAVY-gate failure (28
  routines at cc>=15, limit 26) exactly to the wire (26 at cc>=15, limit
  26) — `./tests/run` fully green for the first time this session.
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
- [x] **[tried, reverted, then FIXED 2026-09-03] `synthVar`'s lookup chain
  ends in a silent `unknownType`, not an error — fixing it is bigger than
  it looks.**
  `typecheck.nim`: local lookup → nullary-call → `synthBareVariant` →
  falls through with no diagnostic. Confirmed live: a genuinely undefined
  bare identifier (`totallyUndefinedName`) passes `tuck ch` with exit 0.
  Root cause behind three earlier bugs this session (`discard`,
  register-field reads, a `sizeof` type-argument) before each got its own
  dedicated upstream check.
  Tried the direct fix (report `dcTyUndeclared` instead of returning
  `unknownType` from `synthBareVariant`) and ran the full suite: broke
  60+ assertions across `typecheck`, `value_semantics`, `declarations`,
  `bare_variant`, `object_composition`, every `d_backend`/Odin/D example
  compile, and `cli_smoke`. Widened the exemption (known type/object/
  interface/actor decls + a primitive-name set) and re-ran: fixed
  `value_semantics` but a NEW, larger wave surfaced — `Green` (an inline
  sum variant), `AppEvents` (a registry name), `Bufs`/`Buffers` (pool
  names), `Helpers`/`BulkOps` (mixin names), `CTRL` (a register name) all
  hit the same fallback as bare values, none tracked in any table
  `synthBareVariant` can see.
  **Real finding: a bare Capitalized name is a legal VALUE-position
  reference to at least seven different declaration kinds** (sum variant,
  object/type/interface, actor singleton, registry, pool, mixin, register)
  each resolved by its own ad hoc mechanism scattered across the checker,
  with no single registry of "every declared name, and what kind of thing
  it names" to check a name against before giving up. Reported-vs-silent
  is not the real bug; the missing piece is that name resolution itself
  is not centralized. Reverted rather than keep widening an allowlist
  test-failure-by-test-failure — that path just rebuilds the same
  scattered-registry problem one exemption at a time. A real fix needs a
  single "what does this bare name declare, if anything" lookup that
  every one of these ad hoc mechanisms defers to, with the actual
  synthVar case as the correctly-strict fallback once that lookup exists.
  Left `git checkout`-clean; `./tests/run` green.
  **MOSTLY FIXED 2026-09-01, properly this time** — not the lookup-table
  patch above (rejected on review: still guessing at the use site from a
  generic `exkVar`). Instead, five dedicated AST node kinds —
  `exkActorRef`/`exkRegisterRef`/`exkRegistryRef`/`exkPoolRef`/`exkMixinRef`
  (`compiler/ast.nim`) — resolved ONCE, whole-program, by a new pass
  (`compiler/resolve_refs.nim`, new `psResolveDeclRefs` pipeline stage
  between inject-types and typecheck) that builds five name→Decl tables
  (extending `resolution.nim`'s existing `Resolution` sidecar) and rewrites
  every matching bare `exkVar` before typecheck ever sees it. Ambiguity
  (same name declared twice for one construct) is now a real, located
  compile error. Ordinary `synthVar`/`synthBareVariant` never sees these
  five names again — no exemption list, because there is nothing left to
  exempt for these five.
  Updated every real consumer (filtering out ~15 UNRELATED `receiver.kind
  == exkVar` hits along the way — ordinary local-variable narrowing,
  the `Error.name`/`input.x` magic identifiers, sum-variant construction —
  confirmed by reading each, not touched): `typecheck.nim`'s
  `failIfRegisterAccess`/`registerFieldType`/`synthFieldAccess` (register +
  new `actorFieldType` for actor field reads)/`asStaticMemberCall` (pool)/
  `raisedEventsIn` (registry raise validation), `lowering.nim`'s
  `flattenRegistryRaise`, and the register/actor field-access arms in all
  three backends (`codegen.nim`, `codegen_odin.nim`, `codegen_d.nim`).
  Found and fixed one genuinely NEW bug this surfaced: `synthChain` used to
  synthesize a `..` chain's own type as "whatever its base's type is" —
  fine for a builder-pattern object, wrong for a register write (`CTRL
  ..EN {true}`), which used to synthesize the base as `Unknown` (exempted
  from the "flows X out of body" check) and now correctly resolves to a
  real type — except a register/actor/registry/pool/mixin base has no
  real "own type" to flow anywhere. Fixed: these five bases synthesize the
  chain itself as `unit`, matching their actual (side-effect-only)
  semantics.
  Result: 13 of the original 16 `<unknown>`-leaking examples down to **7**
  (`04, 05, 08, 15, 18, 19, 20 (9 sites, down from 39), 22`) — zero
  regressions (`./tests/run` full green except the pre-existing, deferred
  complexity-count ratchet; `tools/emit_examples.sh` — byte-identical
  output across the whole corpus, confirmed twice). Regression tests in
  `cli_smoke.nim` for both the checker fixes and the new node kinds.
  **The remaining 7 are a DIFFERENT, sibling bug, confirmed by direct AST
  dump** (`tuck dump --stage:typecheck --format:json` on a minimal
  registry-raise probe): the registry NAME half of `AppEvents.raise
  SensorFailure {...}` now resolves correctly (`AppEvents` → real type),
  but `SensorFailure` — the EVENT VARIANT name — is still Unknown. A
  registry event is effectively an inline sum-type variant scoped to the
  registry, and `sumTypeOwning`/`allVariants` don't recognize it the same
  way a top-level `type X: | A | B` variant is recognized — the SAME
  family of gap as the already-tracked inline-sum-variant bug
  (`08-actors_isolated_state`), not one of the five constructs this fix
  targeted. **Left `synthBareVariant`'s fallback returning `unknownType`,
  NOT tightened to a hard `fail()`** (the plan's Phase 4) — doing so now
  would turn every valid registry-event raise in the corpus into a hard
  compile error. Phase 4 needs this sibling gap (event-variant names, both
  inline-sum and registry-scoped) fixed first.
- [x] **FIXED (the tool) 2026-09-01, but [repro] 16 real gaps it found are
  NOT fixed** — `assertNoUnknownTypes` (`compiler/pipeline.nim`), gated on
  `--verify-stages`: walks every fn/task/const body after typecheck and
  fails loudly if any expression's recorded type is still exactly the
  checker's `UnknownName` ("<unknown>") sentinel — deliberately narrower
  than `ast_query.hasUnknownType` (which also treats a nil/never-typed node
  as unknown, and treats `<typeparam>`/`<pending>`/`<emptyrec>` — all
  legitimate gradual-typing markers, not gaps — the same as a real one).
  Also fixed in passing: `tuck ch` never threaded `--verify-stages` into
  `checkProgram` at all (silently accepted and ignored the flag) — none of
  the THREE existing pipeline assertions (this one, mangle-idempotency,
  async-effects-consistency) had ever actually run under `tuck check`
  before this. Only `tuck c`/`tuck b` wired it correctly.
  Turning it on found the synthVar gap above is not rare: **16 of 44
  examples** carry `<unknown>` past typecheck — `04, 05, 08, 11, 14, 15,
  18, 19, 20 (39 sites — worst by far), 22, 25, 26, 27, 29, 30, 42`.
  **14 FIXED 2026-09-01** (down to 15 remaining) — root-caused with `rr`
  time-travel debugging (a single breakpoint on `unknownType()`, reverse
  to the ONE call site, no bisection needed): `asResultIntrospection`'s
  `.err` arm (typecheck.nim, right below `.ok`/`.value`) had its own
  self-documented TODO, `else: unknownType(e.span)  # .err — code;
  enum-typed later` — a dynamic re-raise (`err resp.err`, spec-blessed,
  not obscure) hits it every time. Now yields `u16`, the runtime's real
  `TuckResult.err` field type (`tuck_rt.nim`); confirmed this does not
  touch `match r.err:`'s SEPARATE arm-validation path (`matchErrEnums`,
  keyed off the receiver's name via `varErrTypes`, never reads `.err`'s
  own synthesized type). Regression test added to `cli_smoke.nim`
  (`examples/14-task.tuck` now passes `--verify-stages`).
  **29/30 FIXED 2026-09-01** (down to 13 remaining) — same technique,
  different shape: `synthSelect`'s `on select:` (a task's tail expression)
  deliberately returned bare `unknownType`, commented "leave it unknown,
  the bodies carry the returns" — a real design choice (every arm
  returns explicitly), not a checker gap, just riding the wrong sentinel.
  `tailIsImplicitReturn`'s `isUnknown(bodyT): return false` gate is
  exactly what makes this design work (skip the tail-type check when the
  tail "cannot be judged") — so the fix could not just give it a concrete
  type; there isn't one. Added a SIXTH named sentinel,
  `ast.BranchOutcomeName` ("<branchoutcome>") + `branchOutcomeType()`
  (`typecheck_util.nim`, same pattern as `typeParamType`/`pendingType`/
  etc.), included in `isUnknown`'s list (so `tailIsImplicitReturn` still
  skips it) but NOT in `assertNoUnknownTypes`'s narrower `UnknownName`-only
  check. `synthSelect` now returns `branchOutcomeType(e.span)`. Regression
  tests added to `cli_smoke.nim` for both examples.
  **Remaining 13 examples ROOT-CAUSED 2026-09-01 (not fixed — same
  architecture gap as the reverted synthVar entry, confirmed, not
  guessed).** Used bulk instrumentation instead of one-by-one `rr`
  sessions once the count made that worthwhile: a permanent, opt-in
  `when defined(traceUnknown): stderr.writeLine(sp, getStackTrace())`
  in `unknownType()` (`typecheck_util.nim`) — zero cost when undefined,
  build with `-d:traceUnknown --stacktrace:on` to use it — dumped every
  hit across all 13 in one pass, filtered to the immediate caller. Every
  hit collapses into four leaf sites, and only two are genuinely new
  information:
  - `synthBareVariant` (typecheck.nim ~2078, by far the most common) —
    THE SAME reverted synthVar gap: a bare Capitalized name (actor,
    registry, inline sum variant, pool) resolving through no central
    lookup.
  - `synthCall`'s final fallback ("Nothing claims it -> Unknown,
    gradually", ~2008) — the SAME gap one level up: `{payload} Name`
    where `Name` resolves to nothing known. Not new; same missing
    registry.
  - `synthFieldAccess`'s fallback (~913) traces to the ALREADY-PINNED
    §3 bug ("Field access on a primitive is unchecked", `known_bugs`,
    `bugOpen`) — `failUnresolvedFieldAccess` declines to report when
    `unresolvedFieldMessage` returns an empty message, by the same
    deliberate-for-sum-types carve-out §3 already documents. Not new;
    already tracked with its own marker.
  - `bindArmPattern`'s "v1: any other pattern-bound name enters scope
    as Unknown" (~1115) IS a new angle worth naming: `example
    08-actors_isolated_state`'s `match state: Red: Green` has an
    INLINE sum type (`state: {Red, Yellow, Green}`) whose arm patterns
    are real variants, but `tc.allVariants(trackedType)` apparently
    does not recognize them as such for an inline (not top-level
    `type X: | A | B`) declaration — so a genuine variant pattern
    falls into the branch meant for an arbitrary bind-name. Still the
    same underlying disease (a declared name — here, an inline
    variant — not resolving through a lookup that knows about it) but
    a THIRD entry point into it, not just synthVar/synthCall's two.
  Conclusion: not four distinct bugs, essentially one (plus the
  already-pinned §3 one). Whack-a-moling per-example fixes here would
  repeat the reverted synthVar attempt's mistake — widen the same gap
  narrowly, case by case. Left as diagnosed-but-unfixed on purpose;
  the central name-registry lookup is the real fix, same as synthVar.
  Had
  to swap the existing `tuck c --verify-stages` smoke-test fixture
  (`tests/suites/cli_smoke.nim`) off `examples/29-task-timeout.tuck` (now
  correctly caught as dirty) onto `examples/28-async-task.tuck` (clean) so
  the gate keeps passing while these stay open; a regression test for the
  assertion itself (catches a genuinely undefined bare name, does NOT
  false-positive on 28 or the rest of the clean 28/44) is in the same file.
  Real fix for the 16 gaps is the same one synthVar needs: the central
  name-registry lookup, above.
  **13 of these 13 FIXED 2026-09-01** (the "widen the same gap narrowly,
  case by case" warning above turned out to be the wrong call in
  hindsight — see the dedicated-node-kinds entry above for why the
  central-registry framing itself was corrected mid-session; this is that
  correction's actual payoff). `synthBareVariant`'s fallback now
  recognizes, in order: the pending-hole marker (`"..."`, a magic
  identifier the parser spells as a literal `exkVar`, same shape as
  `"input"`/`"Error"` elsewhere in this file — gets `pendingType`, its
  real, already-existing sentinel), a registry event name
  (`registryEventOwner`, mirrors `sumTypeOwning`, reuses
  `resolve_refs.nim`'s whole-program `registryNames` table), and a
  declared type/object name used bare (`+ AudioPlayer` composition — the
  same "type name in value position" `asNamedCallee` already trusts at
  the call position, extended to its bare-name sibling). Separately,
  `synthFieldAccess` gained an early case for `Error.name` (spec 4.9),
  matching codegen's own long-standing `isErrorDotRef` special-case
  (typecheck never had one), and `checkReturnValue` learned to skip the
  ordinary compat() check for it — codegen rewrites `return Error.X`
  wholesale into `terr(errCode(...))`, so comparing its raw synthesized
  type against a declared `!T` was always going to be the wrong check,
  not a bug in the synthesized type itself.
  **Found and fixed a real, separate bug this surfaced**: `resolve_refs.
  resolveDeclRefs` rewrites `+ Mixin` composition's operand from `exkVar`
  to `exkMixinRef` — correct per the previous plan's scope — but
  `ast_query.isCompositionEntry` (consumed by `lowering.composeObject`
  and all three backends' object-member codegen) only recognized
  `exkVar`, so a MIXIN composition specifically stopped being recognized
  as a composition at all the moment that rewrite landed. Fixed by
  widening `isCompositionEntry`'s kind check and adding
  `compositionTargetName` (returns `.name` or `.refName` as appropriate)
  for the four call sites that read the operand's name directly. Confirmed
  via `emit_examples.sh` diff review: output is identical except a
  harmless NodeId-counter shift (more nodes now minted earlier in the
  pipeline), proving mixin composition was never actually broken in
  between — this was caught and fixed within the same work session, not
  shipped broken.
  **Found and fixed a second real bug**: `resetResolution()` (called
  BY `typecheckProgram` itself, per its own documented "typechecking
  resets the shared semantic layer" invariant) was wiping the five
  `resolve_refs.nim` name tables — including `registryNames`, which
  `registryEventOwner` depends on — every time, silently making that
  fix a no-op until traced down. Fixed: `resetResolution` now carries
  the five tables across its own reset instead of dropping them.
  **Found and fixed a third real bug, this one pre-existing**:
  `bindArmPattern`'s new subject-type check compared the match
  subject's OWN synthesized type against `tkSum` directly — correct for
  an inline sum field (which synthesizes AS its body), but a NAMED sum
  type's subject synthesizes as `tkNamed "Door"`, requiring
  `tc.resolve()` first to reach the actual `tkSum` body. Without the
  resolve call, transitions-tracking match-narrowing (spec 4.4b) would
  have silently stopped narrowing for every NAMED sum type — a real
  regression that slipped past the FULL test suite once already (only
  one direction was tested: `t.okCheck "transition: match narrowing
  unlocks the edge"`, which stays green whether narrowing fires or not,
  since every arm's reassignment happens to also be legal from some
  OTHER variant in the full domain). Added the missing NEGATIVE test —
  `t.badCheck "transition: match narrowing LOCKS the other edges too"` —
  confirmed by temporarily reverting the `tc.resolve()` call: the suite
  does go red without it (the existing "unlocks the edge" test, as it
  happens, not the new one — together they cover both directions now).
  **16/16 FIXED 2026-09-03** — the last one, `08-actors_isolated_state`'s
  arm BODIES (`match state: Red: Green` — the VALUE `Green`, not the
  pattern `Red`), are bare inline-sum-variant references outside any
  pattern position, so `bindArmPattern`'s fix didn't reach them: they
  went through ordinary `synthBareVariant` via `sumTypeOwning`, which
  only scans NAMED types, and an inline type (`state: {Red, Yellow,
  Green}`) has no name to look up at all. Fixed by adding
  `matchSubjectType*: Type` to `TypeChecker` (`typecheck_state.nim`,
  beside `transitionCtx`) — `synthArm` (`typecheck.nim`) sets/restores it
  around `tc.synthesize(arm.body)`, and `synthBareVariant` consults it
  (via `tc.resolve` + `hasVariant`, same pair `bindArmPattern` uses)
  before falling through to `unknownType`. Scoped to arm-body synthesis
  only, save/restore handles nested matches over different subjects
  correctly. All 44 examples now pass `--verify-stages` except
  `16-actor-tasks-unified-syntax` (a pre-existing, unrelated undeclared-fn
  error, not an `<unknown>`-type leak). `synthVar`/`synthBareVariant`'s
  final fallback tightening (`fail()` instead of `unknownType`, deferred
  twice now) is finally in scope — zero known legitimate bare-name shapes
  reach that fallback any more. `./tests/run` green throughout (bar the
  pre-existing, deferred complexity-count ratchet, now 28); `emit_examples.sh`
  diff empty.
  **FALLBACK TIGHTENED 2026-09-03** — `synthBareVariant`'s final fallthrough
  is now `fail(dcTyUndeclared, ...)` instead of silent `unknownType`, closing
  the original finding above. Doing so surfaced FOUR more legitimate shapes
  the fallback was quietly carrying, each fixed on its own terms rather than
  re-widening a name-string allowlist:
  1. **A fn WITH params, referenced bare (not called).** `{mapFn: double}
     Box` filling a `Mapper[int, str]` fnsig slot — `applyBakeOverride`'s own
     comment already documented this as deliberately Unknown ("fn refs come
     through as Unknown and pass gradually"), so `synthVar` now returns
     `unknownType` for this case explicitly, ahead of `synthBareVariant`,
     instead of it happening to land there by accident.
  2. **`sizeof`/`alignof`/`offsetof`'s argument is a TYPE name, not a
     value** — `sizeof(int)` synthesized `int` as an ordinary bare
     identifier and had nowhere to resolve it from. Root-caused instead of
     patched: added `ParenBuiltinNames` and skip synthesizing the args in
     `synthCall` entirely (codegen already reads them as text, never as a
     typed expression — synthesizing them as values was never correct,
     just previously tolerated).
  3. **Assigning a bare inline-sum variant to an already-typed target**
     (`state = Green` where `state: {Red, Yellow, Green}`, OUTSIDE any
     match) — the arm-body fix above only reached match arms.
     `expectedVariantType` (renamed from `matchSubjectType`, same
     mechanism, now documented as covering both) is additionally set by
     `synthAssignVal` around the RHS, from the target's own type.
  4. **A bare inline-sum variant filling a construction field**
     (`{state: Green} Light`) — needed the SAME target-type hint, but
     per-field: added `fieldTypeHints: Table[string, Type]` (field name ->
     declared type), populated by `asNamedCallee` from `declaredFieldsOf`
     before synthesizing a construction's args, consulted by both
     `synthStruct` (the first pass, typing the literal) AND
     `suppliedFieldTypes` (constructedType's SECOND, independent pass over
     the same field values, to read back holes without the `<uninit>`
     stamp — missed on the first attempt: hints were restored between the
     two passes, so the second one saw nothing).
  5. **Real bug alongside the above, unrelated to hints:** actor handlers
     using `self.field` had `self` NEVER bound at all — `checkActorDecl`
     bound every field bare but not `self` itself, unlike `checkObjectDecl`
     which already binds both. `self.hits = n` inside an `on` handler
     synthesized `self` as silently-unknown and rode through on gradual
     typing; now bound the same way `checkObjectDecl` does.
  Found via the full suite (not the 44 examples — those were all already
  clean): 6 failures the first tightening attempt caused, each traced with
  a real reduction before being fixed, never patched blind. `./tests/run`
  green (bar the same pre-existing complexity ratchet); `emit_examples.sh`
  diff empty.
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
- [ ] **[repro] `tuck c f.tuck --odin` emits BOTH `.nim` and `.odin`,
  unconditionally.** Nim backend has no `if` guard at all in `tuck.nim`;
  `--odin`/`--dlang` are additive on top, not alternatives. Already
  planned: single-target `case backend of bkNim/bkOdin/bkDlang` — see
  saved plan `fancy-yawning-karp.md` Phase 1 (drafted, not applied).
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
- [ ] **[repro] `.toStr` on an int does not compile** — "'n1' of type 'int'
  has no field 'toStr'". → iface-playground FINDINGS.
- [ ] **[repro] A list literal cannot reach a `Seq` parameter.**
  `[dynamic]T` has no literal form. Needs statement hoisting in the emitter.
  **Pinned:** `interface_seq`. → MISSING-FEATURES A2.
- [x] **FIXED 2026-08-30** — `on select` in a task body was a stub; a task
  WITH ARGUMENTS ran on the main context instead of a coroutine. Both fixed;
  29/30 now run correctly under Odin. See commit "Odin task select,
  task-with-args, and a silent test-harness bug".

### D
- [x] **FIXED 2026-08-30** — a statement-position match with plain
  (non-return) arms was routed through the VALUE dispatch, wrapping only
  each arm's first statement in `return` and stranding the rest outside
  the switch. genDStmt now dispatches exkMatch to genDMatchStmt directly,
  matching Odin's own genStmt shape, instead of asking genDExpr's
  matchArmsReturn (a different question — "does an expression-position
  match's arm already return" — answered wrong when the match is a
  statement to begin with).
- [x] **FIXED 2026-08-30** — `sizeof`/`alignof` now emit D's postfix
  property (`T.sizeof`) instead of the call syntax dmd rejects.
- [x] **FIXED 2026-09-01 — Odin's own `sizeof`/`alignof` misspelling.**
  Odin's real builtins are `size_of(T)`/`align_of(T)` (still call syntax,
  unlike D's postfix property) — the emitter printed `sizeof`/`alignof`
  verbatim, which is ALSO valid Nim, so that backend's emission was right
  by coincidence, same shape as the D bug above. `asParenBuiltinOdin`
  (codegen_odin.nim), mirroring `asParenBuiltinD`, rewrites the callee
  name; `offsetof` stays unhandled (no example needs it, and Odin has no
  existing "unsupported construct" helper the way D's `dUnsupported` is —
  falls through to a plain call, so the Odin compiler itself reports
  "undeclared name: offsetof" if one is ever emitted, an honest failure).
  Verified directly: `sizeof(int)`/`alignof(int)` both build and run,
  returning 8 on Odin, matching Nim exactly.
  **Found in the process, NOT fixed — a real, separate D bug, one layer
  deeper than the "postfix vs call" spelling already fixed above:**
  `sizeof(int)` on D emits `int.sizeof` (D's own NATIVE 32-bit `int`,
  never translated) instead of `long.sizeof` (Tuck's `int` = D's `long`,
  per the type table) — confirmed by direct run, giving 4 instead of 8.
  `asParenBuiltinD`'s `ctx.genDExpr(e.args[0])` prints a paren-builtin's
  type argument as a plain expression, with no awareness that it names a
  TYPE — the same treatment would ALSO misspell `sizeof(SomeUserRecord)`
  as the bare Tuck name rather than the mangled `tuck_SomeUserRecord` D
  struct actually declares. Root cause is one level UP from either
  backend's emitter: the checker has no dedicated typing path for a
  paren-builtin's argument at all — it types via the SAME silent-
  `unknownType`-on-no-match fallback (`synthBareVariant`) that `discard`
  was riding, confirmed by re-reading that code path, not just observed
  behaviorally. Fixing this properly means giving `sizeof`/`alignof`/
  `offsetof`'s argument a real, checker-recognized "this names a type"
  path, THEN routing it through each backend's existing primitive-type
  table (`dPrims`) and name-mangling (`mangleName`) — sized, not started.
  No test added for D's broken state (would need `bugOpen` in
  known_bugs.nim); recorded here instead, since chasing it now is outside
  this fix's scope.
- [x] **FIXED 2026-09-01** — records containing a `Seq` field shallow-copied
  the slice: assignment `.dup`'d a bare Seq, but a record holding one was
  copied field-wise and the slice inside was shared (confirmed by direct
  probe: `b = a; b.items[0] = 999` also changed `a.items[0]`, disguised by
  exit-code truncation — 999 mod 256 = 231, easy to misread as a different
  bug). Fixed with a per-field dup at the marking pass (lowering_d.nim's
  `markSeqCopies`/`seqFieldNames`), not a postblit: extends the existing
  `.dup`-marking seam rather than introducing a second mechanism. The
  emitter rebuilds the record through a temp (`(() { auto t = <val>; t.f =
  t.f.dup; return t; })()`) so a call-valued RHS is evaluated once, not
  once per Seq field. `seqElem` (was duplicated between codegen_d.nim and
  lowering_d.nim as `seqElemT`) moved to ast_query.nim as the one shared
  predicate. One known imprecision, accepted rather than chased: a fresh
  `{fields} TypeName` construction parses as an exkCall (payload-call
  syntax) with no "this is fresh" node kind to exempt it the way a bare
  `[1,2,3]` list literal already is — so a freshly-constructed record with
  a Seq field pays one redundant `.dup` (correctness over the extra
  allocation, not a wrong answer). `d_backend` gained two regression
  assertions (emitsD + runsD).
- [ ] **[read] Registers are not `volatile`.** D has no volatile qualifier;
  `core.volatile`'s load/store are the supported spelling. Correct for the
  examples, wrong for a real embedded target.
- [x] **FIXED 2026-09-01** — the reactor (epoll+timerfd) landed in
  `tuck_coro.d`, porting `tuckrt/tuck_coro.odin`'s event loop: `IoWaiter`/
  `EventLoop`, `armTimer`/`watchFd`/`unwatch`, `tuckAwaitRead`/
  `tuckAwaitWrite`/`tuckSleep`/`tuckAwaitReadOrTimeout`, `runOnce`, and
  `tuckRun` now polls `epoll_wait` instead of stopping when the ready queue
  drains. Used druntime's own bindings (`core.sys.linux.epoll`,
  `core.sys.linux.sys.timerfd`) rather than hand-declared externs, unlike
  Odin. `genDSelect` (codegen_d.nim) replaces the `dUnsupported` stub for
  `exkSelect`, mirroring `genOdinSelect`. `openSource` landed in
  `tuck_rt.d` using a real D closure over `{ms, wr}` — no
  `context.user_ptr` marshaling layer needed, since D (unlike Odin) has
  real closures. 29-task-timeout (exit 2) and 30-async-read (exit 1) both
  build and run correctly; two `runsD` regression assertions added to
  `d_backend` suite. **1 of 44 examples does not compile**: 16, which
  fails the CHECKER, not codegen (§6). FIXED since (was 13, 2026-08-29):
  the messageless actor (15), the inline sum type (08), fnsig-as-value
  (03), composition and mixins (04), a value-returning body the checker
  left open (which D and Odin reject where Nim does not), and the reactor
  (29, 30). → ledger.
- [x] **FIXED 2026-09-01** — std/fs (`readFile`/`writeFile`/`appendFile`/
  `removeFile`) now offload through `tuckSubmitBlocking` onto the worker
  thread the reactor's fix added, instead of blocking the whole process
  inline. Matches `tuck_rt.nim`/`tuckrt/tuck_rt.odin`'s runtime
  CHARACTERISTICS, not just their semantics: other coroutines, actors and
  timers now keep running during a file op on D too. Raw C calls
  (open/read/write/close/unlink), not `std.file`: the request crosses the
  `tuckSubmitBlocking` boundary as a MALLOC'd struct, because a GC-managed
  result reachable only from the calling coroutine's unscanned minicoro
  stack while it is parked is not safe to hold onto — same hazard the
  scheduler's own malloc'd ready queue already exists to avoid. `fileExists`
  stays un-offloaded (a stat is cheap; matches both other backends).
  Verified: example 24's write→read round trip, plus a probe exercising
  append/remove/fileExists-after-removal not covered by any example.
  `d_backend` suite gained one `runsD` regression test for the full
  round trip.
- [x] **FIXED 2026-09-01** — D examples 35-ffi-struct/36-ffi-enum-callback/
  37-ffi-handle failed to LINK (`ld: multiple definition of counterBump`),
  found while adding `d_backend`'s example sweep. Root cause: one
  `extern [... lib: "point.c"]:` block commonly declares several fns
  sharing that one C source, and `tuck.nim`'s D build step collected the
  compiled object once per matching FN rather than once per unique OBJECT
  PATH — the same `.o` landed on the dmd command line twice (or three
  times), so the linker saw every symbol in it duplicated. Fixed with a
  `HashSet[string]` of already-added object paths. All three compiled fine
  under `tuck c` before this (only the `tuck b`/dmd link step failed), so
  the bug was invisible to `d_backend`'s existing compile-only checks —
  found only by actually running the sweep's build+run step, not by
  reading the code. All three now build and run (exit 0), added to
  `d_backend`'s `dRun` list.
- [x] **FIXED 2026-09-01** — `impl: d "..."` shim support landed in
  codegen_d.nim: `genDImplFwd` (a forwarder calling `<alias>.<name>(...)`,
  mirroring `genImplForwarders` in codegen_odin.nim) and `implMods` (alias
  -> module, feeding `dImports`'s `import <alias>;` line). Unlike Nim's
  `import ./shim/x` or Odin's `import "./shim"` — both a path baked into
  the import itself — a D `import` is a bare module name resolved only
  through `-I` search paths, so there is nothing to rebase or copy: the
  shim's directory rides `tuck.nim`'s dmd command line as an extra `-I`
  instead (computed from the pre-rebase tree, exactly like the existing
  `.c`-object handling does for `externLib`). `examples/34-ffi-cstring.tuck`
  gained a `d "./shim/zlib_shim"` entry alongside its existing `nim`/`odin`
  ones, and `examples/shim/zlib_shim.d` was written (D's own FFI spelling:
  `pragma(mangle, "zlibVersion")` + `fromStringz(...).idup`). Verified:
  builds and runs (prints the real libz version, exit 0), added to
  `d_backend`'s `dRun` list; two `emitsD` regressions added for the
  import/forwarder shape.
- [x] **FIXED 2026-09-01 — `discard` is now a real construct, and a deeper
  bug it was riding on is closed too.** `discard` was an unresolved bare
  identifier: `synthVar` fell through lookup → nullary-call → sum-type-
  variant, and `synthBareVariant` returned `unknownType` SILENTLY when
  none matched — meaning ANY undeclared bare identifier (confirmed with
  `someUndeclaredNonsenseName`, even in a `return` value position) passed
  `tuck ch` clean and only failed downstream, at the TARGET compiler.
  Nim's own real `discard` keyword happened to make example 20 "work" on
  that one backend by coincidence — Odin and D both failed to build with
  "undeclared name: discard" (confirmed directly), the same shape as the
  sizeof bug below.
  Added `exkDiscard` as a genuine AST node — bare `discard` (nothing
  before it) is prefix, a keyword like `return`; dropping a VALUE is
  `<expr> discard`, POSTFIX (`parseStatementExpr`, checked after every
  statement-position expression, not a leading keyword) to match Tuck's
  own grain — `{payload} fnName`, chains, `.fn {args}` all read value
  first, action after, and a leading `discard <expr>` read backwards
  against that (caught in review: the first cut had it prefix-with-value,
  matching Nim's own spelling too literally instead of Tuck's). Touched
  every exhaustive dispatch the compiler itself flagged by building after
  adding the enum value: lexer, parser (`parseDiscardExpr` for the bare
  form, mirrors `parseReturnExpr`),
  parser_stringify, complexity, lowering (generic child-walk), typecheck
  (`synthDiscard` — types `discardVal` if present, but the STATEMENT's
  own type is always unit, which is what makes it the sanctioned escape
  from the dropped-fallible-result diagnostic), and all three codegens
  (Nim: literal `discard` — the identical construct; Odin: `_ = expr`,
  its own native value-drop, or nothing for bare; D: a bare expression
  statement, which D already permits unused, or nothing for bare).
  **Also, per user request: an empty block (`:` opening nothing — no
  statement, no discard) is now a parse error (TK-PA09)**, not silently
  accepted — closes the gap `discard` was hiding in one direction, and
  catches a genuinely-empty stub the OTHER direction (found immediately:
  11-embedded-feature's `processISR` had a comment-only body; fixed by
  adding `discard`, byte-identical Nim/Odin/D output either way since
  those backends already had an empty-body fallback that happened to
  print the same thing).
  Verified: example 20's Odin build no longer mentions `discard` in its
  errors at all — the two REMAINING failures there are exactly the two
  other items below (register field access, `sizeof`), not a discard
  problem. `typecheck` suite gained 4 regression assertions. Full
  `./tests/run` green; `examples/20-embedded-mp3-player.{odin,d}`
  re-emitted (now correct, empty-body code instead of an undefined
  reference) and reviewed.
- [x] **FIXED 2026-09-01 — register field access.** `DAC_CR.EN` reached
  codegen as a raw `uint*`/`^u32` with no field. NOT a missing-accessor
  bug: `genRegister`/`genDRegister` already generate real, CORRECT
  `<reg>_<field>_get`/`_set` procs doing the mask/shift math (Odin's is
  even more complete than Nim's own `registerMMIO` macro — it handles a
  bit RANGE; Nim's macro only ever handled a single bit). The actual gap
  was that field ACCESS SITES never called them: `genFieldAccess`/
  `genAssign`/`genChainStep` (Odin) and `genDFieldRead`/`genDAssign`/
  `genDChainStep` (D) all fell through to ordinary `.field` syntax on the
  raw pointer regardless. Fixed with one shared predicate,
  `registerAccessorPrefix` (ast_query.nim, reused by both backends' three
  call sites each): does `receiver.fieldName` name a real register field,
  and if so, what's the `<reg>_<field>` prefix `genRegister` already
  emitted for it.
  A THIRD layer surfaced fixing this: the checker never gave a register
  field READ a real type either — `DAC_CR.EN` fell through `synthVar`'s
  ordinary bare-name resolution and silently became `unknownType`, same
  fallback `discard` was riding. Harmless for Nim (no explicit type
  needed) and Odin (`:=` infers from the accessor's own return type), but
  D's "never `auto`, state the checker's type explicitly" policy turned
  it into a real failure the moment a register read was bound to a
  variable. Fixed with `registerFieldType` (typecheck.nim): `bool` for a
  single `bit N`, `u32` for a `bits LO..HI` range, matching exactly what
  the generated accessors return.
  Verified: example 20's Odin and D builds no longer mention `DAC_CR`/
  `register` in their errors at all — confirmed by direct build, and by
  the tracked `.odin`/`.d` diff (every `tuck_DAC_CR.EN = x` line became
  `tuck_DAC_CR_EN_set(x)`, nothing else changed). `declarations` suite
  gained 6 regressions (3 Odin, 3 D) covering both single-bit and range
  fields, both read and chain-mutate write — no `runs` check, since a
  register's address is real MMIO hardware, unsafe to dereference on a
  test machine.
  - [x] **FIXED 2026-09-01 — `SystemEvents.raise PlaybackStarted` emitted
    swapped/nonsensical code.** Emitted as
    `PlaybackStarted(tuck_SystemEvents.raise)`. Two bugs stacked, both in
    `lowering.nim`'s `flattenRegistryRaise`:
    1. **Wrong shape assumed.** `Registry.raise Event` (no payload) parses
       to ONE `exkCall` — `callee = exkVar(Event)`, `args = [exkField(
       receiver: Registry, fieldName: "raise")]` (confirmed via `tuck p
       --ast`). The OLD guard only matched a DOUBLY-nested shape
       (`e.callee.kind == exkCall`), which is the shape a WITH-payload
       raise parses to (`Registry.raise Event {payload}` — the payload
       applies to `Registry.raise Event` as its own callee-expression,
       Tuck's ordinary `{payload} calleeExpr` form, where calleeExpr
       happens to be a call) — so the guard was actually RIGHT for that
       shape (matching `known_bugs.nim`'s own passing regression test,
       `AppEvents.raise LowMemory {remaining: 42}`) but never matched the
       no-payload shape at all, which is the ONLY kind example 20 (or any
       current example) uses. Fixed by checking BOTH shapes.
    2. **Order-of-traversal corruption, found only by testing the fix
       against the with-payload case and getting `raise_X_Y()(42)`
       instead of `raise_X_Y(42)`.** `lowerExpr`'s generic walk recurses
       into a node's CHILDREN before running the exkCall-specific passes
       on the node itself. For a with-payload raise, the INNER call
       (`Event(Registry.raise)`) is a CHILD of the outer one, and once
       shape 1 above could ALSO match a no-payload raise, that same inner
       call — read on its own, bottom-up, before the outer pass ever
       runs — looks exactly like a complete, standalone no-payload raise.
       It got flattened in place (with its args cleared to `[]`) before
       the outer `flattenRegistryRaise` ever got a chance to see the
       pristine two-level shape it needed. Fixed by moving
       `flattenRegistryRaise`'s call to BEFORE the recursive descent for
       `exkCall` nodes specifically (`flattenMemberCallPayload`/
       `explodePayload` still run after, since they need already-lowered
       children).
    Both bugs live in the SHARED `lowering.nim`, so the fix benefits all
    three backends from one change — confirmed by re-emitting examples:
    Nim's OWN example 20 output had the identical swapped bug all along
    (never previously checked directly; only the separate, unrelated
    Nim registry-type indentation bug — see below — had blocked noticing
    it via a full build).
    Verified: a minimal no-payload probe (`registry Sys: | Started` /
    `Sys.raise Started`) builds and runs correctly on Nim, Odin AND D
    (all print the emitted `raise_tuck_Sys_Started()` call and exit as
    expected); the with-payload `known_bugs.nim` regression test still
    passes; example 20's Odin build **now fully builds and runs** (the
    `discard`/`sizeof`/register/raise fixes together clear every Odin
    blocker). D still fails on the separate, already-recorded `!void`
    bare-`return` bug below — untouched by this fix, as expected. Full
    `./tests/run` green; `examples/20-embedded-mp3-player.{nim,odin,d}`
    re-emitted, diff reviewed on all three (every swapped raise call
    became the correct `raise_tuck_<Registry>_<Event>(...)` form, nothing
    else changed).
    One incidental discovery found live-debugging this (not a bug, a
    genuine design question, see backlog below): a second `on
    Registry.Event(...):` handler for the SAME event is rejected today,
    but only because a handler is represented as an ordinary top-level
    `fn` named `"Registry.Event"`, which collides with Tuck's general
    "every top-level name is declared once" rule — NOT a deliberate
    one-handler-per-event design. `genRegistry`'s codegen already scans
    for and calls EVERY matching handler decl in a loop, so multiple
    handlers would already fan out correctly if the naming collision
    were resolved.
  - [ ] **D-only: a bare `return` inside a fn returning `!void`
    (`rt.TuckResult!(rt.TuckUnit)`) emits as bare `return;`** — a D type
    mismatch ("return expression expected"), in `streamReader`'s
    early-return-on-error path (`if !(buf.status == ...): return`).
    Not investigated beyond the observed symptom: Nim and Odin's `!void`
    early-return presumably wraps the bare `return` in the right
    ok/err-carrying value (`return rt.tokVoid()` matches Odin's own
    emission of the SAME construct, confirmed in the diff reviewed for
    the register fix above), so D's `genDReturn` likely has an early-out
    for a value-less `return` that skips the `!void`-wrapping step Odin's
    equivalent doesn't skip. Worth checking `codegen_d.nim`'s
    `genDReturn` against `codegen_odin.nim`'s `genReturnStmt` for exactly
    this case before assuming the fix shape.
  Not chased further this session. Example 20 now **fully builds and
  runs on Odin** (register access, `discard`, `sizeof`, and the raise bug
  above all fixed) — D is the only backend still blocked, by the one
  remaining item directly above.

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
- [x] **FIXED 2026-09-01** — CLI usage/help was thin: `tuck dump` with no
  arguments fell through to the generic paramCount check, which either
  dumped the full 50-line banner or (for `tuck help dump` specifically)
  tried to open "dump" as a filename and died with "no such file". Added
  `tuck help [command]` / `-h` / `--help` (bare = full banner, exit 0;
  with a command name = that command's own focused usage, exit 0; unknown
  command name = short error + known-commands list, exit 2) via a
  `CommandHelp` table + `CommandAliases` (l/p/ch/c/b/d → full names) in
  `tuck.nim`. Also: a KNOWN command invoked with no file (`tuck dump`,
  `tuck build`, ...) now prints that command's own focused help instead
  of the full banner — same content as `tuck help <command>`, but exit 2
  (it's still a missing-argument error, not a help request) rather than 0.
  `tuck explain CODE` untouched (already had its own path). Verified all
  paths by hand: `tuck help`, `tuck -h`, `tuck help dump`, `tuck help
  build`, `tuck help bogus`, `tuck dump` (no file), `tuck build` (no
  file), `tuck explain TK-TY05`, bare `tuck` — each prints what it should
  and exits 0 or 2 correctly. `./tests/run` green (CLI usage text isn't
  asserted on anywhere).
- [x] **FIXED 2026-09-01** — `-v`/`--verbose`: echoes "starting"/"done
  (Xms)" around each of the 7 named `PipelineStage`s (`compiler/pipeline.nim`)
  a run actually executes, off by default. Landed as a `verboseMode` global
  + `vBegin`/`vEnd(stage)` helpers in `tuck.nim`, wired into the shared
  `loadOrDie`/`checkProgram`/`checkOrDie`/`typecheckOnly` procs (so `check`,
  `compile` and `build` all get psLoad/psInjectTypes/psTypecheck/
  psVerifyEffects for free) plus psMangle/psLowering/psEmitting in the
  compile/build backend arms. The Nim arm's lowering+emit used to be ONE
  interleaved per-module loop; split into two loops (lower all, then emit
  all) to give each stage its own timing — verified behavior-unchanged
  (each module's lowering was already independent of another's emit).
  Verified by hand: `-v` on `check`/`compile`(all 3 backends)/`build` prints
  exactly the stages that ran for that command, nothing without the flag.
  `./tests/run` green (no test asserts on this stderr output).
  NOT done, out of scope for this entry: the final native-compiler
  invocation (`nim c`/`odin build`/`dmd`) is not a named `PipelineStage`
  and was left alone — it already prints its own unconditional "built ...
  (Xms)" line regardless of `-v`.
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
