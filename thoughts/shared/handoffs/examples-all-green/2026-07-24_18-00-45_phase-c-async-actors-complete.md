---
date: 2026-07-24T18:00:45+03:00
session_name: examples-all-green
researcher: Kobi
git_commit: 54266294180bc96653e691022902c16bf5f6c99a
branch: main
repository: tuck_lexer
topic: "Tuck async/actor/task runtime (Phase A–C) + extern layer — Implementation Strategy"
tags: [implementation, async, actors, tasks, coroutines, arsenal, extern, operation-timeout]
status: complete
last_updated: 2026-07-24
last_updated_by: Kobi
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: Tuck async runtime (actors + tasks + operation-timeout) shipped; extern layer full

## Task(s)

Built the entire actor/task/async story for the Tuck→Nim compiler, plus made the
`extern:` layer first-class. All COMPLETE + runtime-verified this session:

- **Actor Phase A** (prior sessions, unchanged): singleton actors, `send`, `scheduler::waitUntil`.
- **Actor Phase B**: `on select` for actors (message arms + `shutdown`) as direct `dkSelect` decl node.
- **Phase C — tasks + async** (the bulk of this session), 6 sub-tasks all DONE:
  1. async imports + build flags in `tuck build`
  2. task spawn/run: calling a task schedules a coroutine; `[io]` calls auto-yield
  3. gate example 28 (runtime-verified exit 42)
  4. task results: `let r = {args} task` awaits the return
  5. operation timeout: task `on select` with `read fd`/`timeout ms` racing via the reactor
  6. UNIFICATION: actors + tasks onto ONE cooperative runtime over arsenal (no OS-thread scheduler)
- **Extern layer to full**: single runtime facade (tuck_rt re-exports tuck_async),
  `main` exempt from `[io]`, `[emit: "nimProc"]` attribute.
- **Docs**: `MISSING-FEATURES.md` catalog with user rulings folded in.

PLANNED / NOT built (see Action Items): real async std I/O externs, typed select
sources, `fnsig`, match exhaustiveness, example 16/20 fixes, 5 known-bugs.

## Critical References

- `thoughts/ledgers/CONTINUITY_CLAUDE-examples-all-green.md` — the ledger; its
  ACTOR RUNTIME RULINGS + Phase-C blocks are the AS-BUILT source of truth.
- `MISSING-FEATURES.md` — the "for later" backlog with all rulings (repo root).
- `~/.claude/plans/jolly-toasting-elephant.md` — currently holds the (now-done)
  extern plan; earlier actor design below the banner.

## Recent changes

Runtime (the ONE Tuck runtime over arsenal, engine = minicoro + std/selectors reactor):
- `compiler/tuck_async.nim` — the Tuck runtime: `tuckAsyncInit/tuckSpawn/tuckYield/
  tuckAwaitRead/tuckAwaitReadOrTimeout/tuckRun`, actor primitives
  (`tuckStartActor` = actor-as-coroutine loop drain-then-yield, `tuckNotifySend`,
  `waitUntil`), task results (`newAsyncResult/spawnResult/awaitResult`), and a
  demo async source `openSource`.
- `compiler/tuck_rt.nim:~250` — FACADE: `import ./tuck_async` + `export tuck_async`;
  the OS-thread Scheduler was DELETED (moved+reshaped into tuck_async).
- `/home/kl/prog/arsenal2/src/arsenal/io/eventloop.nim` — added `waitForReadOrTimeout`
  (read-or-deadline race via std/selectors `registerTimer`); IoWaiter got
  pair/outcome fields; debug echoes gated behind `-d:arsenalDebug`. (arsenal is a
  SEPARATE git repo — commits made there too.)

Compiler:
- `compiler/resolution.nim` — `asyncCalls` set + `markAsync/isAsync`.
- `compiler/semantics.nim` — marks `[io]` call sites async; registers local extern
  effects; **main exempt from `[io]`** (full effect budget).
- `compiler/codegen.nim` — `[io]` call in a task → `(tuckYield(); call)`; task call →
  `tuckSpawn`; `let r = task` → result form; `ActorType.field` → singleton;
  `exkSelect` → `if tuckAwaitReadOrTimeout(fd,ms): read else: timeout`;
  `externEmitName` for `[emit:]`; facade `export tuck_rt`.
- `compiler/ast.nim` — new nodes `exkSend`, `exkSelect`, decl `dkSelect`,
  `SelectArm`, `externEmit` field.
- `compiler/parser.nim` — `send`, `on select` (actor dkSelect + task exkSelect,
  replacing the old exkMatch hack), `[emit:"..."]` attr.
- `tuck.nim` — actor/task detection; emits runtime import + `--stackTrace:off
  --lineTrace:off --path:arsenal` on EVERY build; main wiring (init/register/drive).
- Examples 26/27/28/29 + cli_smoke assertions (55/55/42/2).

## Learnings

- **minicoro + Nim WORKS; the libdill crash was libdill-specific.** A Nim coroutine
  yields on a minicoro stack and the GC survives — PROVEN. The earlier "Nim can't
  do foreign-stack coroutines" conclusion was FALSE (it was libdill's `go` macro +
  setjmp). See scratchpad PoCs.
- **MANDATORY build flags for any coroutine/async program: `--stackTrace:off
  --lineTrace:off`.** Nim's stack-walker corrupts the switched coroutine stack
  (SIGABRT at teardown). arsenal's own `tests/test_coroutines.nim.cfg` carries these.
- **arsenal2 (`/home/kl/prog/arsenal2`, `--path:.../src`) is a COMPLETE cross-platform
  async runtime on minicoro**: coroutines + scheduler + fixed_async futures +
  `io/eventloop.nim` (std/selectors reactor) + `io/backends/{epoll,kqueue,iocp}.nim`.
  Import `arsenal/concurrency/coroutines/minicoro` (NOT coroutine.nim — that pulls
  libaco → a benign "executable stack" linker warning; minicoro.nim is clean).
- **NO OS threads in the runtime.** All actors+tasks are cooperative coroutines on
  ONE thread. So actor mailbox locks are unnecessary (single-thread). And
  `openTimerPipe` originally used `createThread` → heap corruption; removed it.
- **`typecheckProgram` calls `resetResolution()`** — so the effect pass (which sets
  `asyncCalls`) MUST run AFTER it in `tuck.nim`, else the async marks get wiped.
- **transitionTo is RESOLVED, not a gap**: caller builds the FULL target variant,
  `transitionTo(self, target)` validates the kind-edge + assigns. Example 12 green.
- **Effect model**: `[io]` marks impure fns (drives async); it is NOT a gate on
  `main` (main is assumed impure). Calling a TASK is a spawn — its effects do NOT
  propagate to the caller.

## Post-Mortem (Required for Artifact Index)

### What Worked
- **PoC-gauntlet-before-building**: proving each vertical slice (coroutine yield,
  reactor resume, read-or-timeout, result-await) in scratchpad before wiring the
  language caught every integration bite early. Highly effective.
- **Exhaustive `case` with no `else`** in the AST dispatch: adding a new node
  (exkSend/exkSelect/dkSelect) made the compiler list every site needing an arm —
  zero missed sites.
- **Thin Tuck-owned runtime API over arsenal-as-engine**: stable surface codegen
  targets; arsenal swappable; Beef will mirror the same names.

### What Failed
- **libdill**: `go` is a C macro (setjmp+setsp), un-FFI-able as a proc pointer;
  worked via `{.emit: "go(fn());".}` but Nim code on its stack SIGABRT/SIGSEGV'd
  even with zero GC. Dead end → abandoned for minicoro. (Pure C libdill worked
  fine — it's a Nim-integration wall specific to libdill.)
- **Beef native async**: `Task` is thread-pool (.NET-style) and raw `Thread`
  heap-corrupts in a standalone Beef console app here. Beef async = ceiling for now.
- **OS thread in `openTimerPipe`**: `createThread` writing a pipe → heap corruption
  with the coroutine GC. Removed; the timeout scenario uses an idle pipe instead.
- **Nim-native asyncdispatch** (briefly proven working) was set aside because the
  runtime must serve Beef too, and both ecosystems converge on minicoro.

### Key Decisions
- Decision: **minicoro (via arsenal2) as the ONE coroutine engine, both backends.**
  Alternatives: libdill (crashes on Nim), asyncdispatch (Nim-only), hand-rolled.
  Reason: minicoro works in both Nim and Beef ecosystems; arsenal already built the
  reactor on it; symmetric backends.
- Decision: **ONE unified runtime — actors are coroutines, not an OS-thread scheduler.**
  Reason: eliminated the two-scheduler drift; single cooperative thread; no locks.
- Decision: **tuck_rt facade re-exports tuck_async; arsenal bundled always.**
  Alternatives: per-extern `[rt:]` marker, conditional re-export. Reason (user):
  simplest; premature to optimize; name-collision = stdlib author's hard error.
- Decision: **operation-timeout via std/selectors `registerTimer`** (not a timer
  wheel, not OS sleep). Reason: the reactor resolves fd + deadline in one `select()`.

## Artifacts

- `MISSING-FEATURES.md` — the backlog (read FIRST for next steps + rulings).
- `thoughts/ledgers/CONTINUITY_CLAUDE-examples-all-green.md` — full as-built history.
- `compiler/tuck_async.nim` — the Tuck runtime (actors+tasks over arsenal).
- `compiler/tuck_rt.nim`, `compiler/codegen.nim`, `compiler/semantics.nim`,
  `compiler/ast.nim`, `compiler/parser.nim`, `tuck.nim` — the compiler changes.
- `examples/26-actor-run.tuck`, `27-actor-select.tuck`, `28-async-task.tuck`,
  `29-task-timeout.tuck` — runtime-verified examples.
- `/home/kl/prog/arsenal2/src/arsenal/io/eventloop.nim` — reactor (separate repo).
- Scratchpad PoCs (session-local, may be gone next session): `mco_yield.nim`,
  `reactor_poc.nim`, `tuck_async.nim`, `timeout_poc.nim`, `to2.nim`.

## Action Items & Next Steps

Ordered by value (all detailed in `MISSING-FEATURES.md` with rulings):

1. **Real async std I/O externs** (biggest — makes async USABLE): an async socket
   recv / async readFile that registers its fd with the reactor + yields, so a task
   does genuine non-blocking I/O and `timeout` races something real. Today
   `openSource` is an idle-pipe placeholder; std fs/io are blocking.
2. **`fnsig` named function signatures** (RULED + syntax): `fnsig Adder = {a:int,
   b:int} -> {sum:int}`; full fn-return parity; use NAME as a type for fn slots/
   callbacks; checker validates call shape. Subsumes the uncallable `fn` slot.
3. **Match exhaustiveness checking** (RULED: full Nim-style — cover all variants or
   catch-all, else compile error). General, all matches.
4. **Typed select sources** — `resp.ok` readiness + `timeout.5s` duration lexing
   (currently opaque strings; only bare `read fd`/`timeout ms` lower). Unblocks 16.
5. **Example 20 codegen bugs**: MMIO register-field DSL (`DAC_CR.EN`) + actor-handler
   transitionTo-with-payload garbage.
6. **Example 16**: `.fn {args}` on undeclared method ruling + the typed select above.
7. **5 known-bugs** (tests/known_bugs.nim): `/=` int→float, toStr+concat, if-expr,
   Beef `[saturating]`, `Box[error]` attribute-word clash.
8. **DX**: #8 match-parse hint, #10a postfix-precedence hint.
9. **ROADMAP**: resource registry §7.4, `when TARGET` §8.3, visibility, pred/set,
   stack budgets, complexity limit, §11 spec-debt rewrite.
10. **Beef async/actor runtime** (ceiling): port the same reactor design over
    minicoro-beef.

## Other Notes

- Gate = `nim check` on emitted Nim (`tests/compile_all_examples.nim` nimCheckExpected).
  Async examples (28/29) can't be nim-check-gated (need arsenal path) — verified
  via `tests/cli_smoke.sh` build+run+exit-code instead. 25/26 nim-check green.
- Full test matrix: typecheck_tests, compile_all_examples, end_to_end, beef_backend,
  known_bugs, cli_smoke — ALL green at handoff.
- `arsenal2` is a separate git repo with OTHER large uncommitted work in its tree
  (28 files) — untouched by us; our arsenal commits are only eventloop/scheduler.
- Standing user prefs (memory): commit freely + after every success; bash = literal
  full paths, Read/Edit not sed/python (I slipped twice — avoid); direct AST nodes,
  no clever reuse.
- Build a task program: `./tuck build X.tuck -o:DIR --root:/home/kl/prog/tuck_lexer`
  (the --root flag sets import search base; arsenal path + async flags auto-added).
