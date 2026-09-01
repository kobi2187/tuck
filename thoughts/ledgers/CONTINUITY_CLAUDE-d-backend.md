# Continuity: D (dlang) codegen backend

## Goal
Third backend beside Nim and Odin: `tuck c --dlang` emits `.d`, `tuck b --dlang`
builds a binary with dmd. Done = the run-verified examples that pass under
`--odin` pass under `--dlang` (same exit codes), suite `d_backend` green.
This is ROADMAP "Experimental #1" — the experiment also *answers* "does the
two-backend discipline generalize" and "where do Nim-isms hide"; findings go
in a DISCOVERIES section at the bottom of this ledger.

## Constraints

**Portable runtime semantics (user, 2026-08-27).** Runtime semantics AND
runtime characteristics must be identical across backends — a program's
observable behaviour and its performance shape should not depend on which
backend built it. That is why fibers/async/actors/scheduling ride on
minicoro everywhere rather than each backend's native coroutines. Other
subsystems should follow the same principle; today some are per-backend
reimplementations (tuck_rt.nim / tuck_rt.odin / tuck_rt.d) rather than one
shared library, which is a known divergence risk, not a design choice.
Implication for M7: the D backend gets minicoro too, NOT core.thread.Fiber
(supersedes the earlier plan note).

**Idiomatic output is allowed, semantics are not negotiable (user).** Goldens
exist, so D may emit its own idiomatic parallel of a construct rather than a
transliteration of the Nim/Odin shape — and the codegen should be tweaked
toward that best-looking output. The constraint is unchanged: whatever it
emits must still deliver exactly what Tuck promises.

**Refactor periodically (user).** Every few milestones, do a pass over the
new code: simplify, improve readability, apply hindsight. Not only when the
complexity gate complains.
- Written in Nim like the rest: `compiler/codegen_d.nim` (+ `codegen_d_util.nim`
  if size demands), mirroring codegen_odin.nim's structure.
- Pipeline invariants (CLAUDE.md): backend lowers its OWN deepCopy; `case` over
  ExprKind/DeclKind/TypeKind takes NO `else`; complexity gate CEILING=22 per
  proc, HEAVY = count of cc>=15 — keep procs small like the Odin file does.
- Mangling already ran whole-program before the backend sees the tree.
- Emitted `.d` under examples/ stays git-ignored initially (the `.bf` precedent)
  until the backend matures; then tracked like `.nim`/`.odin`.
- dmd on PATH: DMD64 v2.113.0-beta.1 (named struct-literal args OK, >=2.103).

## Key Decisions
- Flag: `--dlang` (not `--d`, reads like a typo of `-d:`).
- One `.d` file per Tuck module: entry `<base>.d`, imports `mod_<name>.d`
  (D modules are files, no directory dance like Odin packages). Qualified
  refs via aliased import: `import time = mod_time;` → `time.tuck_ms(5)`.
- Runtime: `compiler/tuckrt_d/tuck_rt.d` copied beside output (Odin tuckrt
  pattern); emitted `import rt = tuck_rt;`, intrinsics as `rt.printLine(...)`.
- Build: `dmd -i -I<outDir>` so imports resolve without listing files.
- Type map: Tuck `int` → D `long` (D int is 32-bit!), `str` → `string`,
  `Seq[T]` → `T[]`, f32/f64 → float/double, iN/uN → byte/short/int/long +u.
- Actors/tasks: NOT early. Emit a loud "D backend: not yet supported" die,
  not silent wrong code. M7 uses MINICORO (see the portable-runtime constraint
  above — this supersedes the original core.thread.Fiber note).

## State
Approved plan: ~/.claude/plans/fancy-yawning-karp.md (T1-T29, 7 milestones).
Ruling: most-identical native D construct, ONLY where semantics identical —
see memory d-backend-semantics-identical. !T = TuckResult value, no exceptions.

- Done:
  - [x] Orientation: driver flow (tuck.nim:400-530), Odin emitter skeleton +
        call machinery read, AST kinds enumerated (24 exk, 21 dk, 9 tk)
  - [x] Milestone 1 — plumbing (hello world end to end, exit 7, stdout ≡ Nim
        backend; dmd build 213ms). Also fixed pre-existing red complexity
        gate: complexity.nim walk cc=23>22, split walkMatch/walkSelect out.
  - [x] T1 tuckrt_d/tuck_rt.d (print/printLine/toStr template)
  - [x] T2 hand-written target hello.d + mod_console.d
  - [x] T3 codegen_d.nim skeleton, exhaustive dispatches, loud dUnsupported;
        extern fwd TODO-comment policy for not-yet-portable signatures
  - [x] T4 --dlang compile path (mod_<name>.d files, aliased imports,
        resolveDCallee for bare-name cross-module calls)
  - [x] T5 --dlang build path (dmd -i -I<outDir>, _d suffix, skip if absent)
  - [x] M2 statements & scalars (T6-T10): let/var with checker-typed decls,
        ops, if/ternary/while/loop/break/continue, foreach ranges (incl +1),
        list literals, tuple foreach, strings (~ concat, .length cast),
        field access (resolved calls, .len), echo→writeln. Probes exit
        77 and 38 on both backends, stdout identical.
  - [x] T28 pulled forward (user: unit tests after each part): harness
        vEmitD verb + emitsD/omitsD/needD/findDmd, --quick includes D
        emission, tests/suites/d_backend.nim (17 assertions incl. dmd
        build+run via needCmdAfter chain). Grow it per milestone.
  - [x] M3 records & calls (T11-T17): TRec hoisting (same FNV hash naming
        as Odin), named-arg struct literals, payload/record-var explosion,
        combinators (bake/alias/merge ports), chains (.. steps as
        statements), pending stubs (fn templates, stderr like Nim), objects
        (struct + Obj_member free procs, ref self — probe: 9), imported
        type qualification, input payload rebuild, generic extern
        forwarders (templates), bracket at/setAt via resolved calls,
        Seq .dup on assignment (aliasing probe: 64 both). Examples 01, 02,
        07, 18, 41 run-identical to Nim backend; 17 compiles (specimen).
        Suite now 28 assertions. Invariant-carrying paths die loudly (M4).
  - [x] T18/T19 sum types + match: payload-free sums are plain D enums,
        match is `final switch` (D re-checks exhaustiveness — the guarantee
        Tuck makes), value-position match is an immediately-called lambda
        keeping that check. Bare tags qualify to their enum. Example 39
        run-identical. PAYLOAD sums deferred: broken in Nim AND Odin too
        (see DISCOVERIES) — fix the authority first, in one pass for all
        three backends.
  - [x] T20 !T/?T as TuckResult: carrier in tuck_rt.d (status/err/value,
        tok/terr/tnone/tfwd/tokVoid/ok), NOT exceptions. Error codes are
        folded by the emitter and match Nim/Odin exactly (verified:
        "Math.Odd" == 55587 in all three). Wrapped returns, raise, .ok,
        record payloads, !void. Runtime filled out along the way:
        readFile/writeFile/appendFile/removeFile/fileExists, argCount/argAt
        (entry point seeds them via rt.tuckSetArgs), getEnv (absence, not
        error), nowMs, readLine. Examples 24-stdlib, 38, 39, 41 now run
        byte-identical. New helper `tuckRec!(R, "field")` lets the runtime
        fill the CALLER's hoisted record shape — Odin declares a parallel
        struct per extern instead.
  - [x] T22 invariants, written to ROADMAP ruling 5 rather than inheriting
        the Nim backend's bug: guarded by `version (tuckNoInvariants)`, so
        checks stay ON in a release build and strip only when asked. All
        four production sites validate (construction, chain mutation,
        return, extern boundary). NOT `assert` — dmd's -release strips
        those, which silently undid the ruling (verified: an assert-based
        version passed in release). Emits an explicit test calling
        rt.tuckInvariantFailed, which aborts naming the condition.
        Example 10 compiles. Suite asserts all three build modes.
  - [x] T24 (part) + fnsig: [saturating] ctors clamp via rt.tuckSat/tuckSatI
        (example 40 identical — a miss returns 4464); const emits a D `enum`
        (compile-time) or `immutable`; static_assert is D's own native
        `static assert`, no workaround (Odin has to defer its to a runtime
        check in the entry point). fnsig is a D `function` pointer, NOT a
        delegate — Tuck has no captured environment, so the bare pointer
        loses nothing. A fn used as a VALUE takes `&`: a bare name in D
        value position is a nullary CALL. Decided by the checker's type
        (tkFunc), not the node kind — a `:ref` arrives as exkVar or
        exkQualified depending on spelling (verified by instrumenting).
        Example 31 runs 42 on both.
  - [x] M4 rest, M5, M6 — DONE. This section was stale (last touched when
        the sweep was 17/44); all of T21 error policy, T23 interfaces, T24
        decision tables, T25 mod_*.d, T26 extern flavours, T27
        emit_examples, T28 harness+d_backend suite, T29 example sweep
        happened across the sessions logged below and are not re-listed
        per-task here — see TODO.md's own D section for the live,
        currently-accurate list of what remains.
  - [x] 2026-08-30: the D match-statement bug (below, "BUG (D, open)")
        fixed — genDStmt now dispatches a statement-position exkMatch to
        genDMatchStmt directly, mirroring Odin's genStmt, instead of
        asking genDExpr's matchArmsReturn (a value-position question).
  - [x] 2026-08-30: sizeof/alignof fixed — D's postfix property (`T.sizeof`)
        instead of the call syntax Nim happens to share and dmd rejects.
        `offsetof` stays an explicit dUnsupported, no example to verify a
        translation against.
  - [x] 2026-08-30: a member call with a payload mis-bound self — two
        checker bugs (asPostfixApplication's dotArg guard; synthMethodCall
        conflating the top-level-mutator and object-member-implicit-self
        conventions) plus one Odin codegen bug the fix exposed (member
        calls never took the receiver's address for self: ^T). D was
        already correct here; only Odin and the checker needed fixing.
        Full writeup: TODO.md §3, commit 7356d30.

**Current sweep (2026-08-30, reconfirmed): 41 of 44 examples compile under
`--dlang`.** Three remain:
  - **16-actor-tasks-unified-syntax** — fails the CHECKER (undeclared
    methods in an aspirational specimen), not codegen. Not a D task.
  - **29-task-timeout, 30-async-read** — need the reactor. Sized precisely
    below (M7): D's coroutine engine and task-with-args already work;
    only epoll/timerfd/tuckAwaitReadOrTimeout/openSource are missing.

  - [ ] M7 concurrency — PARTIALLY DONE, not Fiber: D uses minicoro, same
        as Odin (per line 21/55 above — this label was stale). tuck_coro.d
        already has the coroutine engine (spawn/schedule/tuckYield/tuckRun,
        spawnResult/awaitResult) — and task-with-args needs NO marshalling
        here at all, unlike Odin's context.user_ptr workaround, since D's
        delegates capture arguments as real closures. What's still missing
        is the REACTOR: no epoll/timerfd, no tuckAwaitRead/
        tuckAwaitReadOrTimeout, no openSource — confirmed absent by reading
        tuck_coro.d's full proc list. That's the actual size of 29/30 for
        D — porting Odin's epoll+timerfd reactor, own plan when reached.
        Odin's own reactor (compiler/tuckrt/tuck_coro.odin) is the
        reference to port from — it already works (29/30 pass under
        --odin as of 2026-08-30) and names the exact six syscalls needed
        (epoll_create1, epoll_ctl, epoll_wait, timerfd_create,
        timerfd_settime, close).

## Open Questions
- UNCONFIRMED: D sum-type shape — mirror Odin (tag enum + one struct holding
  every payload) vs D unions vs std.sumtype. Start with the Odin mirror,
  revisit when match emission lands.
- UNCONFIRMED: ?T lowering — Nullable!T (std.typecons) vs tiny TuckOpt(T) in
  tuck_rt.d. Leaning TuckOpt: no phobos dependency question, same shape both
  backends.
- UNCONFIRMED: whether `dmd -i` picks up tuck_rt.d reliably from outDir or
  needs explicit file list.

## Working Set
- Branch: claude/spec-code-audit-34xh4q
- New files: compiler/codegen_d.nim, compiler/tuckrt_d/tuck_rt.d
- Touched: tuck.nim (compile + build paths), later tests/harness.nim,
  tests/suites/all.nim, tests/suites/d_backend.nim
- Test: ./quick-test.sh (must stay green — D backend is additive),
  scratchpad hello: /tmp/claude-1000/-home-kl-prog-tuck-lexer/*/scratchpad/
- Reference emitters: compiler/codegen_odin.nim (structure to mirror),
  compiler/codegen.nim (Nim semantics), compiler/codegen_common.nim (shared)

## DISCOVERIES (the experiment's real product)
- D `int` is 32-bit; Tuck/Nim/Odin `int` is 64. First Nim-ism found before
  writing a line: any backend assuming `int` widths silently truncates.
- Nim-ism #2 (verified with dmd, wraps at 2^31): `auto x = 0` in D is a
  32-bit int, while Nim's `var x = 0` infers 64-bit. The Nim backend gets
  64-bit inference FREE from Nim; any other backend must state the
  checker's type at every declaration. Fix: genDAssign emits the stamped
  type (dDeclType), auto only for sketch-mode Unknown.
- Nim-ism #3: `.len` rides through the Nim backend untranslated because
  Nim shares Tuck's spelling AND signedness. D's `.length` is size_t
  (unsigned) — poisons later arithmetic via promotion. Emitted as
  `cast(long) x.length`.
- Checker lets a PREFIX call slip through silently: `echo total` (wrong —
  Tuck is postfix) typechecks and emits `total(echo)` in the Nim backend.
  Gradual typing reads both names as Unknown. Same §0 trap family as
  FRICTIONS #1's fnsig workaround. Not fixed here (recorded per user
  instruction: record bugs midway, go on).
- BUG (Nim backend, pre-existing): a value-returning call as a bare
  statement emits an un-discarded Nim call — `{self: c} bump` alone on a
  line dies in the Nim backend with "expression 'bump(c)' is of type 'int'
  and has to be used (or discarded)". Needs a `discard ` prefix on
  dropped-result statements (Odin already has genDroppedResult plumbing).
- BUG (checker, pre-existing): `items[0] = 0` where items is a PARAM
  typechecks — bracket assignment bypasses the TK-TY15 write-through-param
  rule — then dies in the Nim backend (`setAt` wants var). The checker
  should reject at the bracket-assign site.
- D slices alias on assignment where Tuck/Nim seqs copy — verified
  divergent (b[0]=50 wrote a[0] before the fix). Emitter now .dups every
  Seq-typed assignment except fresh list literals. KNOWN GAP: a record
  containing a Seq field still shallow-copies the slice on struct assign;
  needs a probe + per-field dup (or a postblit) when records-with-seqs
  actually appear.
- DIVERGENCE (Nim backend stricter than D, T20): `acc + good.value.value`
  where acc is `int` and the payload field is `u16` compiles in D (implicit
  widening) and FAILS in Nim ("type mismatch"). Same Tuck source, same
  emitted access path — the difference is purely the target language's
  arithmetic rules leaking through. This is exactly what ROADMAP's
  2026-08-24 numeric ruling addresses: once conversion is always explicit
  in the SOURCE, neither backend gets a say. Until then the two disagree
  about which programs exist, which is a portability hole. Backends must
  not paper over it independently — the fix belongs in the checker.
- BUG (mine, fixed in T20): the same record shape hoisted under TWO names —
  `TRec_fs_content_2C8C` in the declaring module (modPrefix) and
  `TRec_content_2C8C` in the caller — so D saw two distinct types for one
  Tuck record. Odin never hit it because `:=` infers and never spells the
  type; stating declared types exposed it. Fixed by naming a foreign shape
  through its owning module. Worth knowing: a backend that infers hides
  cross-module identity bugs a backend that declares will find.
- The checker often stamps a type on the CALL but not on the `let` target
  (verified by instrumenting: target read nil for `let r = {..} fs::readFile`).
  Read the value's type first, the target's second.
- RULE (user, 2026-08-27): the emitted D NEVER uses `auto` or `var`. Tuck
  has a typechecker, so every declaration's type is a fact already
  established; asking the target compiler to re-infer makes two inference
  algorithms agree by luck, which is exactly how the 32-bit `auto x = 0`
  divergence got in. A type the backend cannot state is a GAP, reported
  loudly. Everything ELSE takes the idiomatic road, as long as it is
  equivalent to the Tuck input.
- BUG (checker, found by enforcing the rule above): `s.len` is stamped
  `<unknown>` — a FAILED stamp, not a missing one. The Nim backend hides it
  by emitting `var n = s.len` and letting Nim infer; the D backend cannot,
  so it surfaced. Worked around by supplying `int` (what the language
  guarantees) where isLenOnSized holds; the checker should stamp it.
- SEAM (2026-08-27): compiler/lowering_d.nim is the D backend's own lowering
  pass, running after the shared lowerModule on this backend's deepCopy.
  Rule for what belongs there: rewrites that exist because D's SEMANTICS
  differ from Tuck's (the Seq .dup), not because D spells something
  differently (`~`, `foreach`) — the latter stays in the emitter. Marks ride
  a NodeId side-table: NOT sourceName (holds the user's written name for
  diagnostics) and NOT the shared Resolution (this is a D-only fact). Ids are
  global, so the table must not be cleared per module.
- WHY THE BACKENDS STILL DUPLICATE PAYLOAD EXPLOSION (measured, not assumed):
  shared lowering needs `semLayer.callParamsFor`, and the checker leaves it
  EMPTY for pending fns, distinct-type ctors (`5 Milliseconds`) and the
  combinators (`alias`). Every backend therefore keeps a decl-list-scan
  fallback. Extending explodePayload to qualified callees removed one reason
  for the duplication; recording those params at the checker would remove
  the rest, and is the real fix. Deleting the backend copies before that
  would break the corpus — verified by instrumenting, not by reading.
- PERF (measured 2026-08-27, user asked whether the Nim backend's `*Fast`
  hash lookups would help the others): emit is QUADRATIC in all backends —
  D's share of a compile went 0.03s / 0.11s / 0.38s for 200 / 500 / 1000
  types, i.e. doubling n roughly quadruples the time. Nim is quadratic too,
  with a smaller constant (0.04 / 0.16 / 0.43).
  * compiler/decl_index.nim now shares the index shape (record/actor/task
    names, invariant types, saturating types). Keyed by nothing: a Module is
    a value object with no identity, so a global cache cannot be written
    safely — the backend builds one and passes it.
  * That alone barely moved the needle (0.84 -> 0.80): those five queries
    were not the hot ones.
  * THE REAL HOT SPOT, found by instrumenting: `getFieldsForType` prefers
    the checker's recorded type edge (`semLayer.declForType`) and falls back
    to a decl-list scan when it is missing — and the edge MISSES EVERY TIME
    (200 fallbacks for 200 types). Each miss is a full scan, per node.
    The fix belongs in the CHECKER (record the edge), not in a backend
    cache. Same shape as the callParamsFor gap: work that belongs in an
    earlier stage is being redone per-expression at emit time.
- ACTOR POLICY GAPS (probed 2026-08-29, both reproduced on the NIM backend —
  see scratchpad/actor-playground/FINDINGS.md and FRICTIONS.md #9's update):
  * **A full mailbox drops silently, and waitUntil then hangs.** queue 4 +
    10 sends + a predicate needing all 10 = spins forever. enqueue returns
    false on a full ring and every caller discards it, so the sender cannot
    tell and the predicate can never hold. The D backend matches this
    deliberately rather than inventing a fourth behaviour: the policy is
    unstated in spec 9.1, so choosing one is a LANGUAGE decision.
  * **send without waitUntil never delivers.** 10 sends, no wait, got = 0 —
    main never yields, so the daemon never runs and the program exits with
    the mailbox untouched. An actor program with no waitUntil and no task
    does nothing at all.
  Both are upstream of any backend. Recorded, not papered over.
- BUG (upstream, example 20): an actor `on` handler containing a registry
  raise emits nothing usable in EITHER backend — the Nim output has no proc
  for the handler at all, and the D output shows the un-flattened
  `PlaybackStarted(tuck_SystemEvents.raise)` tree. lowering DOES walk actor
  handlers (allFns -> members() yields dkActor.handlers), so the cause is
  further up. Not a D bug; recorded rather than chased.
- BUG (D) — FIXED 2026-08-30. A statement-position match whose arms are
  plain statements wrapped them in `return` — visible in example 20 as
  `case X: return self.state = ...`, with the rest of the arm's statements
  stranded outside the switch entirely. genDStmt now dispatches exkMatch
  straight to genDMatchStmt when reached as a statement, bypassing
  genDExpr's matchArmsReturn (a value-position question) — mirrors Odin's
  genStmt, which already had this exact direct dispatch.
- D function templates instantiate per call site, so pending stubs and
  generic externs (`toStr[T]`) map 1:1 onto Nim's generic procs — no
  boxing, same monomorphization story.
- BUG (Odin backend) — FIXED 2026-08-27. A `match` whose arms are `return`
  statements emitted Odin's ternary with `return` inside it:
  `return ((s == Kind.Dot) ? return 0 : ...)`, not valid Odin. ROOT CAUSE
  was a duplicate: codegen_odin kept a private injectTailReturn missing the
  `matchArmsReturn` guard the shared ast_query version has. Deleting the
  copy WAS the fix — the duplication was the bug, not merely untidy. Now
  emits a proper switch; verified it builds and runs on the real Odin
  toolchain (exit 2, matching Nim and D).
- BUG (both existing backends, pre-existing): **payload-carrying sum types
  do not work end to end.** `type Shape: | Dot | Line({length: int})` with
  `match s: Line: return s.length` typechecks, then:
  * Nim backend emits `case s` (not `case s.kind`) → "selector must be of
    an ordinal type"; payload reads emit `s.length`, but the declared
    layout is `s.line.length`; and construction drops the payload
    entirely (`tuck_Shape(kind: Line)` for `Shape.Line {length: 5}`).
  * Odin backend emits the invalid ternary-with-return above.
  Payload-FREE sums are fine in both (probe: exit 23). So M4's T18/T19
  scope to payload-free sums + match; payload sums need the AUTHORITY
  fixed first — a language-level gap, not a D one. Worth its own task
  after the backend, since fixing it in three backends at once is the
  cheapest moment.

## 2026-08-29 — session 3

D emits 39 of 44 examples (was 31). Three fixes, each verified by compiling
the emitted D with dmd by hand, not merely by the emitter not dying:

- **A messageless actor.** `actor X: ...` has no handlers and no shutdown,
  so it has no message envelope — and therefore nothing to hold a mailbox
  OF. Emits state + singleton only, matching Nim. `actorHasMessages` is
  asked by both the actor emitter and the entry point, so they cannot drift
  into starting a drain that was never emitted.
- **A value-returning body the checker left open** (a `...` pending hole).
  D rejects falling off the end; so does Odin (`return {}`); Nim does not.
  A NIM-ISM found, which is what this experiment is for. D spells it
  `return typeof(return).init` and needs no knowledge of the return type.
- **An inline sum in a field position.** Hoists to `<Owner><Field>Kind`,
  the name the other two backends already use. Its tags needed a hoist
  table because `enumTagOwner` scans DECLARATIONS and an inline sum has
  none — an emit-time re-derivation of a checker fact, and the table is the
  tactical half of the fix.

### The duplication was the bug again

Chasing a zero-parameter member (`fn advance() -> int` on an object) found
`self` being prepended AT EMIT TIME by each backend separately: codegen's
genMemberFn and codegen_odin's genOdinMemberFn were the same twenty lines
with one word different, and D had no copy — which is why D was the one
that broke. Moved to `lowering.normalizeSelf`, which states only what is
true everywhere (`self` exists; `Self` means the object); each backend
keeps its own spelling of how self is passed (`var T` / `^T` / `ref T`).
Re-emitting every example left the tracked .nim and .odin output byte
identical.

Third instance of the pattern in this project (after injectTailReturn and
decl_index): a fact copied N places gets fixed in one, and the copy that
does not exist yet is a bug waiting for its backend.

### Still open, in order of what they need

- 03 fnsig-as-value, 04 mixins — D emitter arms, self-contained.
- 29/30 `on select` TASK form — needs the reactor (epoll+timerfd). The
  big one.
- 16 — fails the CHECKER, not codegen. Not a D task.
- Inline sum with a DEFAULT (`state: {...} = Red`) still dies:
  "type application <uninit>[...]". Not investigated.

### Later the same day — 41 of 44

- **fnsig (03).** `bake` is fully lowered before codegen, so what arrives is
  plain record construction and the only missing piece was the type:
  `alias BinOp = long function(long, long)`. `function`, NOT `delegate` —
  D keeps them distinct and what fills a slot is a top-level fn with no
  captured environment. Nim's {.closure.} and Odin's `proc` both accept a
  bare proc where that is written, so neither backend had to choose.
  NIM-ISM #3. Verified by running: 7 on both backends.
- **Composition and mixins (04).** `+ X` means fields-merge for a record
  type and fns-merge for a mixin. Moved to `lowering.composeObject`, which
  runs before normalizeSelf so a spliced mixin fn still gets its `self`.
  Deleted the two backend copies; tracked output byte identical.
- **A chain feeding a call.** `self ..loadEpisode {episode} .startAudio`
  emitted `tuck_startAudio(    self = tuck_loadEpisode(self, episode);\n)`.
  A chain is STATEMENTS and statements sequence rather than nest, so it
  runs into a temp. threadReceiver (moved to ast_query) makes each step
  read the previous step's result — without it two steps both read the base
  and the first result is silently dropped.

### The duplication count is now five

isCompositionEntry, takesSelf and threadReceiver joined injectTailReturn
and normalizeSelf in ast_query/lowering. Every one was found the same way:
the D backend lacked the copy, so D was where the bug showed. The pattern
is reliable enough to use as a search strategy — a construct D gets wrong
is worth checking for a duplicated implementation before writing a third.

### Found, fixed 2026-08-30

A member call WITH A PAYLOAD mis-bound `self`: `d.crank {step: 1}` against
`fn crank({step: int})` reported "expects int but got Deck". Example 04
declares `play` and never calls it, so no example caught this at the time.
Fixed — two checker bugs plus one Odin codegen bug the fix exposed; see the
2026-08-30 entry below and TODO.md §3, commit 7356d30.

## 2026-08-30 — Odin task select + task-with-args (unblocks 29/30's authority)

Went to port the D reactor for 29/30 from Odin as reference — found Odin's
own `on select` for the TASK form was a hard-coded stub, and task calls with
arguments never actually ran as coroutines. Fixed both in Odin first, since
D has nothing correct to port from otherwise. Odin now runs 29 (exit 2) and
30 (exit 1) correctly — the two opposite outcomes of the same read-vs-timeout
race, matching Nim exactly.

Root causes, in order found:
- `genOdinExpr`'s `exkSelect` arm was literally `"/* on select: not yet
  lowered for Odin */"`. Only the TASK form hit it — actor `on select`
  lowers separately at the declaration and already worked (verified: 27
  genuinely computes 55). genOdinSelect races read-fd vs timeout via
  rt.tuckAwaitReadOrTimeout, mirroring Nim's genExprSelect.
- A task call WITH ARGUMENTS ran as a direct call, not tuckSpawn — Odin's
  isTaskName+tuckSpawn path was NULLARY ONLY (documented, "designed, not
  guessed" per thoughts/bugs-found-while-building-net.md #5). Fixed via
  context.user_ptr, verified safe by reading newCoroutine/trampoline first
  (co.ctx = context captured at spawn time, restored before entryPoint
  runs). This ALSO turned out to be needed by 28-async-task, which passed
  its exit-code check by accident — it has no fd op whose timing exposes
  running on the wrong context.
- openSource (the demo async source both examples need) had no Odin port;
  the rt-forwarder for an extern in the ENTRY module was unconditionally
  skipped ("or emit nothing (entry module)" — an assumption nobody's own
  file would ever declare its own rt-implemented extern).

A design mistake worth remembering: my first cut of the task-args fix had
`spawnResult` ALSO use context.user_ptr, for its OWN {slot, body} — nested
inside the caller's ALREADY-set env, and the two collided. Found only by
RUNNING it (segfault, gdb to the exact line), not by typechecking or by
reading the code. One env, one wrapper, one context.user_ptr layer per
spawn is the actual rule — see the comment on TuckAsyncResult in
tuck_coro.odin.

### A fourth bug, found by regression-testing the first three

Testing 29/30 needed `tests/odin_out` deleted and rebuilt fresh — something
apparently never done before, since a stale one always happened to be lying
around. That exposed: `for base in compileList: (let b = base; proc(dir) =
stage(b))` does NOT give each closure a fresh `b` in this Nim — verified
with a two-line repro printing the last iteration's value three times.
Every build's prep hook was staging the SAME (last) example's package for
EVERY OTHER example — 37 of 38 examples' `compile` checks had been silently
re-testing whatever stale content happened to be sitting in their directory
from god-knows-when, not the current emitted output. Fixed by routing the
capture through a proc parameter (`stagePrep(base): proc(dir) = stage(base)`
— a parameter DOES get its own binding per call, verified with the same
repro shape) and confirmed stable across three independent cold starts.

This is worth generalizing: `let x = loopVar` inside a `for` loop, captured
by a closure built in that same loop, is NOT a safe pattern in this Nim —
grep for it before trusting a similar loop elsewhere.

## 2026-08-30 — session 5: three more fixes, D holds at 41/44

Picked smaller items off TODO §5 while the reactor (M7, above) stays its
own task. All three verified by running the emitted code, not just by it
compiling.

- **D match-statement bug fixed** (see the DISCOVERIES entry above, no
  longer "open"). Chasing it to a full dmd build of example 20 surfaced
  the sizeof bug next.
- **sizeof/alignof fixed.** D's postfix property, not the call syntax
  Nim/C/Tuck share. Chasing example 20 further past this hit register
  field access on a raw pointer — the SAME error a real Odin build of the
  same emitted source gives, confirming it's a pre-existing, cross-backend
  lowering/typecheck gap in register modeling, not a D bug. Recorded in
  TODO §3/§5, not chased — along with a second finding, a bare `discard`
  no-op that is not a real construct in ANY backend's grammar and has
  apparently never actually been run on any of the three, since example
  20 was never in any backend's compile- or run-checked list.
- **Member-call-with-payload self-binding fixed** (TODO §3). Two checker
  bugs plus one Odin codegen bug the fix exposed — full writeup in TODO.md
  and commit 7356d30. D itself needed no change; this was upstream.

D's own remaining gap is exactly what it was before this session: the
epoll+timerfd reactor for 29/30 (M7 above). Everything else found this
session was either D-specific-and-fixed (match statement, sizeof) or
upstream-and-fixed (the member-call bug) or upstream-and-recorded
(register field access, `discard`, both example-20-only and pre-existing
on every backend).
