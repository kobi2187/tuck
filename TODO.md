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
  property (`T.sizeof`) instead of the call syntax dmd rejects. Odin's own
  `sizeof(x)` emission is STILL wrong (real Odin spelling is `size_of(T)`)
  — unfixed there since no example has reached that line yet (see below).
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
- [ ] **[repro] Example 20 is unverified on every backend past emit.**
  Two blockers remain, both cross-backend and neither D-specific
  (confirmed directly building Odin's own emission):
  - `register DAC_CR at 0x...` field access (`DAC_CR.EN = true`) reaches
    codegen as a raw `uint*`/`^u32` with no field — a lowering/typecheck
    gap in register-field modeling, not a backend bug.
  - `sizeof(T)` — see the Odin misspelling entry below.

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
