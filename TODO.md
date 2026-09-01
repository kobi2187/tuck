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

- [ ] **[repro] Generic `fnsig` does not parse.** `fnsig Mapper[T, U]` is a
  parse error, which blocks every higher-order generic API. The dangerous
  part is the workaround that LOOKS fine: a non-generic `fnsig` with bare
  `T`/`U` typechecks because gradual typing reads them as `<unknown>`, so it
  silently disables checking on the callback. → FRICTIONS #1.
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
- [ ] **[read] Invariants stay on in release (ROADMAP ruling 5).** Done in
  the D backend (`version(tuckNoInvariants)`); the NIM backend still
  hardcodes `when not defined(release)` into emitted code, so its invariants
  cannot be kept in a release build at all.
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
- [ ] **[read] `synthVar`'s lookup chain ends in a silent `unknownType`,
  not an error.** `typecheck.nim`: local lookup → nullary-call →
  `synthBareVariant` → falls through with no diagnostic. Root cause found
  behind THREE separate bugs this session (`discard` riding a checker gap,
  register-field reads resolving to Unknown, and a `sizeof` type-argument
  case) — each looked like an unrelated feature gap until traced back here.
  Fix: last arm should report an error naming the identifier, never
  silently return `unknownType`.
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
- [ ] **CLI usage/help is thin.** User tried `tuck dump` with no
  arguments and got no usage explanation for what it needs. Ask
  (2026-09-01): every `tuck <command>` that needs extra parameters
  should explain its own usage when invoked without them, and there
  should be a `tuck help <command>` giving easy-to-understand,
  per-command help — not investigated at all yet (no read of `tuck.nim`'s
  current arg-parsing/usage-banner code done for this specifically).
  Same theme, added 2026-09-01: **`tuck build` (and presumably `tuck c`)
  should have a `-v`/verbose flag reporting every stage and operation as
  it runs** — currently there is NO verbosity flag at all (confirmed:
  `grep -n "verbose"` in `tuck.nim` finds nothing). Not designed —
  would presumably hook the same `PipelineStage` enum the `--verify-stages`
  work already introduced (`compiler/pipeline.nim`), echoing a line per
  stage transition rather than (or alongside) running the verification
  assertions.
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
