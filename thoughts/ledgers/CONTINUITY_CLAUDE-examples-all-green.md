# Continuity: examples-all-green

## Goal
All 25 examples emit Nim that (a) passes `nim check`, (b) is semantically
equivalent to the Tuck source (emitted code DOES what the source says —
runtime-verified where a main exists). Gate grows from 15/25 toward 25/25;
each newly-green example joins nimCheckExpected (and beefCheckExpected
when Beef also compiles it).

## Constraints
- TDD: failing gate entry / test first, then the fix.
- Semantic equivalence beats nim-check: alias() currently emits a NO-OP
  pass-through (genCall: `alias` → args[0]) — 01's alias line is silently
  wrong today even though 01 nim-checks. Fixing alias fixes 01's semantics
  and 18.
- Suites after every phase; commit per phase (standing OK).
- Beef backend mirrors every codegen change (parity commitment).

## Key Decisions
- Audit method: compile each example, nim check with sanitized module name
  (m_NN_name), read first error (scratchpad/exaudit script, rerunnable).
- Order: bugs first, then sketch-decl edits, then features by size.
- ACTOR RUNTIME RULINGS (2026-07-23) — full plan at
  ~/.claude/plans/jolly-toasting-elephant.md. Phase A IMPLEMENTED + shipped
  (commits 59e256a, aaf706d, b567ecc); rulings below are the AS-BUILT truth,
  refined during implementation from the original plan.
  MECHANISM:
  - Borrow ONE primitive: minicoro (single-header stackful C, public-domain).
    arsenal2 (/home/kl/prog/arsenal2) already vendors it + a tested Nim
    wrapper: import arsenal/concurrency/coroutines/minicoro via
    --path:/home/kl/prog/arsenal2/src. minicoro is the proven part; its
    libaco/libdill wrappers are broken/experimental — use minicoro ONLY.
  - minicoro gives ONLY the suspend/resume stack-switch, and is NOT wired yet
    — Phase A needs no coroutine (handlers run to completion). It joins in
    Phase C for [io] yield. Everything else (Mailbox, scheduler, ready-queue,
    on-select, timers, dispatch) is OUR Nim code in tuck_rt.
  THREADING / LIFECYCLE (Erlang/Elixir-style):
  - Scheduler = a DAEMON on its OWN background OS thread; actors are polled
    cooperatively on it (one kernel thread total, not per-actor). Actors run
    ALONGSIDE main, never exit.
  - MAIN owns the lifecycle. CLI ends when main returns (value-returning main
    = exit code). To wait for actor work: `scheduler::waitUntil {pred: :fn}`
    — main blocks on a predicate over PUBLIC actor state, cond-var-woken
    after each drain sweep (no busy-poll). NOT actor-triggered sys::exit.
  - Actor = global SINGLETON by declaration (no construction, no ref; like
    the §10 event registry). Auto-registered at startup. `ActorType.field`
    reads the singleton; `ActorType send handler {payload}` enqueues.
  - Full mailbox DROPS silently (fast, non-blocking; sender checks hasRoom).
    Ruling: mechanism stays simple; backpressure is the sender's job.
  AST / SURFACE (all DIRECT — no clever reuse, standing user pref):
  - `send` = dedicated exkSend node (parser branch, checker, Nim codegen).
  - `scheduler::waitUntil` = ordinary rt fn + existing `:name` fn-ref; needs
    NO compiler support (laziness falls out of passing a fn not a value).
    std/scheduler.tuck declares the extern.
  - Result out of an actor = a PUBLIC actor field main reads (not sys::exit,
    not a shared global). Registry-based event waits are a later option.
  - `on select` (Phase B) will get its OWN dkSelect + SelectArm nodes, NOT
    the current exkMatch-fake-subject hack (parser.nim ~1305-1330 to replace).
  STACK MODEL:
  - Stackful minicoro = backend #1 (hosted). Stackless hand-rolled = declared
    FUTURE backend #2 (bare-metal), reachable via the thin Coro seam. Stackful
    means [io] needs NO body-splitting: `call; coroYield()`.
  PHASE C ASYNC-I/O INVESTIGATION (2026-07-23, UNRESOLVED — no code landed,
  Phase A/B untouched on main; snapshot branch `phase-a-hand-scheduler`):
  - GOAL restated by user: TRUE async concurrency (I/O in parallel, calls
    yield until they return), ZERO syntax markers (no async/await; the [io]
    marker at the call site is what transforms — effect system IS the async
    annotation), fire-and-continue, looks EXACTLY like a sync call. All
    "threading" = coroutines/fibers, NOT OS threads. Must be CROSS-PLATFORM
    (incl. Windows) AND serve the BEEF backend too, not just Nim.
  - minicoro/libaco = Level-1 (raw stack switch only, same tier). libdill/
    libmill = Level-2 (coroutines + epoll/kqueue REACTOR + channels + timers
    + choose/select). True async I/O needs Level-2. minicoro can NOT be the
    reactor — it only switches stacks; a separate readiness engine is
    mandatory (this was a user misconception, corrected).
  - PROVEN by PoC (scratchpad): libdill's go+suspend works PERFECTLY in pure
    C (flag=7). The SAME thing hosting a Nim coroutine body CRASHES
    (SIGABRT→SIGSEGV), even with ZERO GC work in the coroutine (only a cint
    store, raises:[]/gcsafe/noinline forced). Root cause is NOT (only) GC —
    it is Nim-compiled code running on libdill's foreign swapped stack /
    setjmp. libdill.a is fine; libaco/minicoro/ucontext (nimcoro) ALL hit the
    same foreign-stack↔Nim wall (nimcoro's own README: "confuses Nim's GC").
    libdill's `go` is a C MACRO (#define go dill_go, setjmp+setsp) — bindable
    only via {.emit: "go(fn());".}, never as a proc pointer (this was the old
    "troublesome" memory, now understood).
  - THE FORK (undecided): the runtime must serve BOTH Nim and Beef.
    (a) One portable C runtime (libdill/libmill or our own), both backends
        bind it. Beef may bind it CLEANLY (no tracing-GC-on-foreign-stack
        problem like Nim has) — libdill could work for Beef where it crashes
        for Nim. Nim side needs a workaround or a different suspension.
    (b) Per-backend native runtimes: Nim uses std/selectors (stdlib reactor,
        cross-platform incl Windows, no FFI) + CPS or std/asyncdispatch
        (no foreign stack → no crash class); Beef uses its own. Same Tuck
        surface, different codegen per backend. Clean but two impls.
    (c) Write our own minimal C reactor+coroutine runtime with a C ABI both
        backends bind (a mini-libdill). Most control, biggest build.
  - Beef's async/coroutine/C-interop story is UNRESEARCHED — needed before
    choosing. NEXT: research Beef concurrency; decide the fork. std/selectors
    IS the reactor for the Nim side regardless (stdlib, not hard). The hard
    part is portable suspension that both backends share.
  RESOLUTION (2026-07-23, user ruling): STEP BACK from actors/schedulers/C
  coroutines. Implement TASKS + async via EACH BACKEND'S NATIVE async — Nim
  → std/asyncdispatch, Beef → its own. Fork option (b), per-backend native.
  No FFI, no foreign stack, no crash class. Tuck surface identical; only
  codegen differs per backend.
  - PROVEN by PoC (scratchpad/async_poc.nim, async_timeout.nim): asyncdispatch
    gives (1) real concurrency — two tasks with 200ms [io] each finish in
    ~200ms not 400 — and (2) REAL operation-timeout via withTimeout — a
    deadline fires on a RUNNING [io] op (the thing impossible on blocking
    I/O). async/await/Future all codegen-emitted, INVISIBLE in Tuck source
    ("looks like sync", user's requirement). Cross-platform (asyncdispatch =
    IOCP on Windows).
  - MAPPING codegen must emit (Nim): `task f({x}) -> !T [io]` →
    `proc f(x): Future[T] {.async.}`; each [io] call → `await <call>`;
    calling a task → `await`; main → `waitFor`; `!T` → Future[TuckResult[T]];
    task `on select` timeout.Nms → withTimeout.
  - SCOPE agreed: tasks via asyncdispatch + operation-timeout select FIRST;
    actors (Phase A/B hand scheduler) LEFT ALONE for now, relationship
    deferred. Beef async = later (parity ceiling meanwhile).
  - OPEN prereq for the build: codegen must know a call is [io] to insert
    `await`. Effect info lives in semantics.nim's checker (declared table) but
    is NOT yet surfaced to codegen. Need: mark [io] call sites (callee's
    declared effects) so codegen awaits them. Also: [io] externs (std/http
    etc) must return Future[T] — today std/* externs are blocking; the async
    ones need an async-extern story. These two are the first things to settle
    when building. Actor Phase A/B code is committed + green; nothing here
    touched it.
  BREAKTHROUGH (2026-07-23) — the async FOUNDATION IS PROVEN, on minicoro,
  and ARSENAL2 ALREADY BUILT IT. User instinct vindicated: everything led
  back to minicoro; build/reuse a reactor ON minicoro (not libdill).
  - The libdill crash was libdill-SPECIFIC (its go-macro/setjmp fighting
    Nim), NOT a general "Nim can't do foreign-stack coroutines" wall.
    minicoro + Nim WORKS: a Nim coroutine yields on a minicoro stack and the
    GC seq survives across the yield (PoC mco_yield: @[0,1,2,3]).
  - CRITICAL BUILD FLAG: `--stackTrace:off --lineTrace:off` is MANDATORY for
    coroutine code — Nim's stack-walking corrupts on the switched coro stack
    (that was the teardown SIGABRT). With it off: clean, 13M switches/sec.
    arsenal's own tests/test_coroutines.nim.cfg carries exactly these flags.
    Tuck MUST emit these flags when building an async/actor program.
  - arsenal2 (/home/kl/prog/arsenal2, --path:.../src) is a COMPLETE
    cross-platform async-I/O runtime on minicoro, already built + tested:
    coroutines/coroutine.nim (newCoroutine/resume/coroYield/destroy),
    scheduler.nim (ready queue), fixed_async.nim (zero-alloc futures + await
    across yields — test_fixed_async PASSES), io/eventloop.nim (std/selectors
    reactor: waitForRead/waitForWrite suspend a coro, run() polls+resumes),
    io/backends/{epoll,kqueue,iocp}.nim (Linux/BSD-mac/Windows), io/
    async_socket.nim, channels/, nursery.nim, workstealing.nim.
  - KEYSTONE PROVEN (PoC reactor_poc.nim): a coroutine suspended on a pipe fd
    via loop.waitForRead, the reactor (epoll via std/selectors) detected
    readiness and RESUMED the coroutine → got="hello". Real non-blocking I/O
    + coroutine suspend/resume, end to end, no crash. This is the whole
    Phase-C third leg, working.
  - REVISED PLAN: Nim task backend = arsenal2's runtime (import it via --path,
    like we do for minicoro). Beef backend = minicoro-beef (jazzbre) + port
    the same reactor design (arsenal's is the reference impl) — SAME minicoro
    characteristics both sides, symmetric. Codegen maps task→coroutine,
    [io] call→waitForRead/await-on-fixed-future, on-select timeout→scheduler
    deadline. NEXT: decide how tuck imports/vendors arsenal (path vs vendor),
    then the [io]-call-site marking + async-extern story, then task codegen.
    caveat: arsenal is the user's own, "half experimental" — verify each
    slice as we wire it (as we've been doing).
  RUNTIME SHIM DESIGNED + PROVEN (2026-07-23): arsenal's scheduler is NOT
  elegant enough to expose directly (debug echo spam, split scheduler/
  eventloop, round-robin only). Ruling: Tuck emits its OWN thin runtime API,
  redirects to arsenal as the swappable engine. Beef mirrors the SAME API
  over minicoro-beef.
  - Tuck shim API (PoC scratchpad/tuck_async.nim, result=20, clean output):
    tuckAsyncInit() / tuckSpawn(fn) / tuckAwaitRead(fd) / tuckAwaitWrite(fd)
    / tuckRun() — the last UNIFIES arsenal's split scheduler+eventloop into
    one drive-to-completion call. This is the seam codegen targets.
  - arsenal PATCHED (its own repo, commit 514febd): debug echoes in
    scheduler.nim + io/eventloop.nim gated behind `-d:arsenalDebug` (silent by
    default via a `dbg` template). arsenal tests still pass; reactor PoC now
    clean. NOTE arsenal repo has OTHER large uncommitted work in its tree
    (28 files) — untouched by us; our commit is only the 2 echo-gated files.
  - The tuck rt module for this will live in tuck (compiler/ or a new
    async rt file), import arsenal via --path:/home/kl/prog/arsenal2/src, and
    tuck build must emit --stackTrace:off --lineTrace:off + that --path for
    async programs. NEXT unchanged: [io] call-site marking → async externs →
    task codegen emitting tuckSpawn/tuckAwaitRead/tuckRun.
  PHASE C — TASKS RUN (2026-07-24, DONE + runtime-verified). Committed:
  - compiler/tuck_async.nim: the thin Tuck runtime shim over arsenal
    (tuckAsyncInit/tuckSpawn/tuckYield/tuckAwaitRead/tuckAwaitWrite/tuckRun),
    unifying arsenal's split scheduler/eventloop into one tuckRun().
  - [io] call-site marking: resolution.nim (asyncCalls set + markAsync/isAsync)
    set in semantics.nim when a call's callee carries emIo. CRITICAL ORDER:
    typecheckProgram resetResolution()s, so verifyModuleEffects (which marks)
    now runs AFTER it in tuck.nim, else marks were wiped.
  - codegen: an [io] call inside a task body (ctx.inTask) emits
    `(tuckYield(); <call>)`. A task CALL (`{args} worker`) emits
    `tuckSpawn(proc() = discard worker(args))` — scheduled as a coroutine.
    Calling a task is a SPAWN: its effects do NOT propagate to the caller
    (main calling an [io] task needs no [io]) and the caller doesn't suspend.
  - tuck build: when the program declares any dkTask, emits `import
    tuck_async`, --stackTrace:off --lineTrace:off, --path:arsenal/src, and
    wires main = tuckAsyncInit(); main(); tuckRun(); quit(mainRc).
  - Example 28-async-task: task with two [io] yields computes base*2, sys::exit
    42. Runtime-verified in cli_smoke (8/8). Full matrix green.
  - CEILING/COSMETIC: arsenal's coroutine.nim pulls backend.nim→libaco, unused,
    giving a benign "missing .note.GNU-stack / executable stack" linker
    warning. Importing minicoro.nim directly (not coroutine.nim) would drop it.
  REMAINING Phase C (todo #4, #5):
  - #4 task RESULT model: tasks return !T; `let r = {args} fetch` must yield the
    caller the result once the task completes (result slot / arsenal
    FixedFuture; caller awaits). Today task calls are fire-and-forget (discard).
  - #5 OPERATION TIMEOUT (headline): task-side `on select` with timeout.Nms →
    scheduler deadline racing a REAL async I/O op (non-blocking read via
    tuckAwaitRead on an fd). Also fixes: local `extern:` block fns don't
    register [io] effects (semantics.nim only registers dkFn/dkTask/dkActor —
    a local extern's fns aren't in `declared`, so async-marking misses them);
    and replaces the leftover parseSelectExpr exkMatch hack (task-position
    select) with a proper node.
  PHASES: A scheduler + send + waitUntil (DONE, ex 26 exit 55) → B dkSelect
  nodes + timers + `5s` lexing (ex 16) → C [io] yield (wire minicoro) → D
  transitionTo-in-handler (ex 20) → E spec §9 rewrite. Beef actors = ceiling
  (comment-only, no minicoro path). Nim backend only for now (user ruling).

## State
- Done:
  - [x] Audit: 15 green / 9 broken, each classified (2026-07-13).
  - [x] Phase 1: chain-in-tail-return BUG fixed (both backends,
        idempotent across shared AST; cli_smoke runtime case exits 42).
        17's residue = `merge`/`input` keyword feature → new phase 6b.
  - [x] Phase 2: 09 rewritten (enum columns → exact analysis, catch-all row
        was provably unreachable and removed) + 12 rewritten (real decls;
        pseudo `transition` calls → comments). Exposed + fixed a REAL
        emitter gap: payload-variant construction `{p} Type.Variant`
        emitted `Type.Variant(args)` — invalid in both backends. New
        sumVariantCtor (Nim: kind-tagged object ctor; Beef: kind +
        positional TRec) hooked into both call paths + bare exkField.
        Gates now 17/25 both backends.
  - [x] Phase 3: 04 GREEN both backends. Interface contracts (dkMixin
        member, nil body) emit nothing; mixin fns with `self` materialize
        only at `+ mixin` composition (Self → object, self: var T / ref T);
        `+ RecordType` embeds as a field; object member fns gain
        self: var ObjName (Nim) / ref ObjName (Beef — call-site ref marker
        is a named ceiling); checker binds `self` in object scope; emitNim
        now two-pass (types before procs — Nim decl-before-use vs Tuck
        order-independence; object type headers via ctx.typeSection).
        Gates 18/25 both.
  - [x] Phase 4: alias() REAL. Checker types the result (renamed record;
        bad source field / non-ident target = errors). Nim emits the
        renamed tuple (temp-bind for non-var receivers); Beef emits the
        renamed TRec positional ctor (exkVar+ty only, else pass-through
        ceiling). Fixes 18 AND 01's silent no-op. Gates 19/25 both.
  - [x] Phase 5: bake v1 LANDED (user ruling: Factor-fry model, Nim-generic
        lowering). `:name` fn refs emit bare; `fn` type → `auto` (Nim
        monomorphizes); bake = typed struct rebuild (override/add, value
        overrides type-checked); `slot.invoke {args}` builtin calls
        through the slot. Runtime-verified: partial application exits 7.
        03 in Nim gate (20/25). CEILING: Beef bake pass-through — needs a
        delegate-type story (03 not in Beef gate, still 19).
  - [x] Phase 6b: `input` + `merge` LANDED (user rulings). input = the fn's
        whole payload struct, bound by the checker (params record),
        codegen rewrites input.x → x and bare input → param-tuple/TRec
        rebuild. merge = FLATTEN: union of member structs' fields, name
        collision = error, non-struct member = error; Nim emits the flat
        tuple, Beef the union TRec. Runtime-verified (merge probe exits
        33). 17 rewritten and in BOTH gates: Nim 21/25, Beef 20.
  - [x] Control flow loops (2026-07-19, spec 2.6/3.6b): unified for
        (cond/iter/indexed), loop:, break/continue (depth-checked), spaced-..
        ranges (Nim convention), fn inline. Runtime exit-17 smoke both
        backends. Bugs fixed on the way: block:-captured break (now
        `if true:` wrapper), value-returning main → quit(main()), msgpack
        cache Defect-vs-stamp, continue-keyword vs errors-policy.
  - [x] AST architecture pass (2026-07-22): the tree is now pure SYNTAX and
        the semantic layer lives beside it. Every Expr/ChainStep carries a
        NodeId assigned at the parse boundary; the checker writes calls,
        types and shortcut sites into a Resolution keyed by that id
        (compiler/resolution.nim, global `semLayer`). ty, shortcutSite and
        all five side-node fields (callNode x2, varCallNode, brCallNode,
        brAssignNode) are GONE from ast.nim. Each backend deep-copies the
        checked tree before lowering, so Nim's lowering no longer mutates
        what Beef then reads — ids survive the copy, which is why the
        id-keyed layer was worth having. Also: the two genExpr overloads
        merged into one (they had diverged in BOTH directions, 196 lines
        deleted), and every ExprKind dispatch lost its `else` so a missing
        arm is now a compile error. Research basis: rustc TypeckResults /
        Roslyn SemanticModel vs Nim semArrayAccess; rulings recorded in the
        commits.
  - [x] `[saturating]` REAL (2026-07-22, spec 4.1). Root cause was the
        PARSER: `type X = u16 [attr]` had its trailing attrs clobbered by
        the pre-`=` ones, so the attribute never reached any backend —
        [wrapping] and [trapping] were dead too. Store-guard design (clamp
        where a value is stored, on a wider intermediate) not per-operator:
        `a + b - c` all 60000 is 60000, not 5535. ~3 branchless instructions
        (cmov), measured. Ceiling: u64 has no wider intermediate.
  - [x] `or return` DROPPED (2026-07-22). Never worked — codegen-only
        pattern match, emitted invalid Nim. and/or/xor are strictly boolean
        now, ENFORCED (there had been no operand rule at all: `5 or "x"`
        typechecked). ?T in a boolean position reads as "is present".
  - [x] Pool §7.2 LANDED (2026-07-23). `pool X = ElemType [count: N]` —
        arbitrary element type (not always an array; 7.4 pools files and
        connections). Own DeclKind like registry/arena. count REQUIRED (a
        pool without one has no static footprint). No on_full: exhaustion
        is ?T absence and the caller decides. release goes through the POOL
        (the element may be a primitive with no methods). rt ObjectPool
        rewritten from ptr/nil to TuckResult[T]. Example 11 GREEN + new
        example 25-pools (runtime-verified, exit 4). Gate 23/25.
  - [x] Early-return guards NARROW (2026-07-23). `if not r.ok: return` now
        narrows the rest of the fn, for !T and ?T alike, provided the branch
        always exits. Underneath was a parser bug: `not r.ok` parsed as
        `(not r).ok` — unary took a primary, so the guard shape the checker
        wanted never existed. Unary now binds looser than `.field`/`[i]`
        (`-p.v` was equally wrong). Narrowing lives in exkBlock, since an
        early-return guard narrows its SIBLINGS, not its subtree.
  - [x] `.fn {args}` RULED + fixed (2026-07-23, commit 4c85a84). A brace
        after `.name` proves call intent; an undeclared callee is now a
        clean checker error (synthFieldAccess), not a silent field read with
        the arg dropped. Closed known_bug #8 (open bugs 6→5). Gate harnesses
        walked ALL examples and crashed on the new error for non-gated 16 —
        now a non-gated compile failure is caught+skipped, a gated one still
        raises. Also added `--root:DIR` CLI flag (modules.resolveImport +
        tuck.nim): import search base so std/ + siblings resolve regardless
        of cwd or binary location (test runner, installed tuck). 16 still
        broken — needs actor runtime (Phase 8), NOT closed by this.
  - [x] ACTOR PHASE A (2026-07-23, commits 59e256a/aaf706d/b567ecc). Actors
        RUN. rt: thread-safe Mailbox (+hasRoom, silent-drop on full) and a
        cooperative Scheduler on its own background OS thread (drain closures;
        tuckSchedulerStart/StartActor/NotifySend; waitUntil blocks on a
        `progress` cond broadcast per drain sweep). lang: new exkSend AST node
        (`ActorType send handler {payload}`), actor = singleton (genActor
        emits <type>Singleton + drain + registerActor), `ActorType.field`
        reads the singleton, tuck.nim injects scheduler boot before main.
        std/scheduler.tuck extern `waitUntil`. Erlang-style: main owns
        lifecycle, `scheduler::waitUntil {pred: :fn}` waits on public actor
        state. Example 26-actor-run: send 1..10, wait sum==55, exit 55 —
        runtime-verified (cli_smoke) + nim-check gated. Gate now 24/25 Nim.
        Beef actor = ceiling. NEXT: Phase B (dkSelect + timers, ex 16).
- Now: [→] Actor Phase B: `on select` §9.3 — dkSelect/SelectArm nodes
  (replace exkMatch hack), timer wheel, `5s`/`1s` duration lexing. Then C
  ([io] yield, wire minicoro from arsenal2).
- Remaining:
  - [ ] Phase 3: 04 — `Self` mapping + interface/manager emission + empty
        setMany body indent (`proc setMany(self: Self,...)` invalid Nim).
  - [ ] Phase 4: alias() restructuring lowering (spec 2.5) — fixes 18 AND
        01's silent no-op (semantic!). Checker knows field maps; codegen
        emits tuple rebuild `(id: x.trackId, name: x.title, ...)`.
  - [ ] Phase 5: 03 — bake real specialization (spec 3.5; emits garbage
        `x((someFunc: _add))` today).
  - [x] Phase 6: 11 GREEN (2026-07-23) — pool landed and SensorEvent (a
        defect in the EXAMPLE, undeclared) added.
  - [ ] Phase 6b: 17 — `input` keyword + `merge` (structural merge = future
        language keyword per user). Needs a design ruling first.
  - [ ] Phase 7: 20 — transitionTo-with-payload inside actor handler emits
        `PlayerState.Decoding(transitionTo(self.state))(rate)` garbage;
        register DSL depth (`DAC_CR.EN = true` — MMIO attrs).
  - [→] Phase 8: 16 — actor Phase A DONE (see above). Remaining for 16:
        `on select` §9.3 (Phase B — dkSelect nodes + timers + `5s` lexing)
        then `.fn {args}` handler methods. Runtime strategy fully RULED (see
        ACTOR RUNTIME RULINGS). 16 also needs its undeclared `copyFrom`
        method resolved (currently the `.fn {args}` checker error).
  - [ ] Phase 9: semantic-equivalence pass — runtime-verify every example
        with a main (extend gate to build+run+assert where feasible).

## Gate: Nim 24/26, Beef 20/26 (2026-07-23)
`.fn {args}` RULED+fixed (undeclared = checker error) and actor Phase A shipped
(26-actor-run GREEN + runtime-verified). Remaining broken: **16** (`on select`
§9.3 = actor Phase B; plus its undeclared `copyFrom` handler method), **20**
(MMIO register fields — `DMA1_CH3 ..EN` — + transitionTo-in-handler), **03**
Beef-side only (delegate types). Example 26 is the new actor gate entry.

## known_bugs suite (tests/known_bugs.nim)
Every confirmed bug, open or fixed, written as an assertion of CORRECT
behaviour plus a `fixed` flag. Fix a bug -> flip its flag -> the same
assertion becomes a permanent regression guard. The suite fails BOTH when a
fix lands unflagged and when a fixed bug returns. Currently 6 open, 6 fixed.
Open: `/=` on ints emits float `/`; toStr loses str-ness under `+`; `if` has
no expression form; Beef does not clamp [saturating]; a type ARGUMENT named
like an attribute (`Box[error]`) still fails (the valued half `[name: value]`
is fixed, bare markers still use the word list); `.fn {args}` on an
undeclared fn.

## Open Questions
- bake (03): what is v1? (a) true inline rewrite per spec 3.5, or (b) bind
  the fn-ref into the struct (proc-typed field, call through it) with
  inlining later. Also needs rulings: `:name` fn-ref literal semantics,
  `op invoke {args}` call-through syntax, and the `fn` field TYPE story
  (currently maps to `pointer` — uncallable).
- `when TARGET` §8.3 + top-level statements / implicit main (20).
- **16's `.fn {args}` on an undeclared fn** — `buf.copyFrom {data}` emits
  `self.buf.copyFrom`, a field read with the argument silently dropped.
  Ruling needed: resolve it as a call anyway (sketch-friendly), or report
  copyFrom as undeclared? Silently emitting a field access is neither.
- User asked for MORE TESTS AND EXAMPLES, a few per feature. Pool now has 8
  tests + a usage example; most older features still rest on one example
  each. That was the standing request when the session ended.
- `input` keyword + `merge` (17) — structural-merge keyword design.
- on select §9.3 (16) — still behind the actor-runtime strategy ruling.
- 20: transitionTo-with-payload inside actor handlers emits garbage —
  mechanical fix possible once the intended lowering is confirmed
  (what does `{rate} PlayerState.Decoding transitionTo` mean in a
  handler? construct-then-checked-assign to self.state?).
- UNCONFIRMED: does 04 need interface satisfies-checking (spec 5.2/5.3) or
  just emission fixes to go green?
- Phase 8 needs a user ruling on the task runtime before it can start.
- `{5}`-style timeout sugar in 16 (`timeout.5s`) — syntax itself may need
  a ruling (5s lexing).

## Working Set
- Audit script: scratchpad/exaudit (rerun: see 2026-07-13 session)
- Gate lists: tests/compile_all_examples.nim nimCheckExpected,
  tests/beef_backend.nim beefCheckExpected
- Test: full matrix — typecheck_tests, compile_all_examples, end_to_end,
  cli_smoke.sh (BEEFBUILD_BIN=~/apps/Beef/IDE/dist/BeefBuild), beef_backend,
  known_bugs
- known_bugs (2026-07-22): every confirmed bug, open or fixed, asserted as
  CORRECT behaviour plus a `fixed` flag. Fix a bug -> flip its flag -> the
  same assertion becomes a permanent regression guard. Suite fails both when
  a fix lands unflagged and when a fixed bug returns. 5 open, 1 fixed.
