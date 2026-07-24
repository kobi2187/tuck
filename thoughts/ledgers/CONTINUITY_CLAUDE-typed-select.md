# Continuity: typed-select

## Goal
Replace opaque select-source strings with typed sources, driven by splitting
example 16's tangle into FOCUSED single-feature examples (unit-test style).
Each example proves one feature and gets its own gate entry. "Done" = all four
phases below green (cli_smoke + matrix + Beef where applicable).

## Constraints
- TDD: failing test/example first, then the fix.
- Rulings (user, 2026-07-24):
  - `timeout.5s` / `timer.1s` syntax REMOVED — unsupported. Durations use
    stdlib DISTINCT unit types: `timeout {5.ms}` where `ms` is a tiny helper
    `fn ms({value: int}) -> Milliseconds` (distinct over int).
  - A bare literal `n` = the payload `{value: n}` — so `5.ms` passes
    `{value: 5}` into `ms`. Rides the existing payload-explode convention;
    no special-casing. [[literal-value-payload]]
  - `.` in a source parses as ORDINARY field access (`resp.ok`), not opaque
    source-string glue.
- Direct AST nodes, no clever reuse (dkSelect/SelectArm already exist).
- Beef mirrors codegen where feasible; ceiling otherwise.

## Key Decisions
- ex16 is DECOMPOSED, not fixed in place: its features (durations, typed
  timeout, actor timer/shutdown select, future readiness, `.fn` method) each
  become a separate small example.
- Phase order: foundation-first (durations → timeout → actor select →
  readiness), readiness LAST because its runtime model is still open.

## State
- Done:
  - [x] Phase 1: duration types. std/time now declares distinct Milliseconds/
        Microseconds/Seconds + `ms`/`us`/`s` helpers. Fixed a cross-module
        codegen bug: `5.ms` where `ms` is IMPORTED emitted a bare `5` (field
        read) instead of `ms(5)` — codegen's literal-.method path only checked
        the local module; now isKnownFn scans imported modules too. Example
        32-duration-units (exit 42) + cli_smoke gate. Matrix green.
        NOTE found: distinct->base readback (`n u32`) emits `u32` not `uint32`
        — a separate codegen gap, sidestepped in ex32, worth a known-bug later.
  - [x] Phase 2: `timeout {5.ms}` typed in a TASK select. Codegen unwraps the
        `{dur}` payload and emits `int(<dur>)` for tuckAwaitReadOrTimeout; a
        bare `timeout 30` still passes through. Examples 29 (exit 2) + 30
        (exit 1) retyped to `timeout {30.ms}` / `{100.ms}` with `import time`.
        cli_smoke + matrix + Beef (32 examples) green.
- Now: [→] Phase 3: ACTOR `on select` periodic `timer {..}` arm — DEFERRED,
        needs a design pass first (user ruling 2026-07-24). Actor select
        already handles named message arms + reserved `shutdown` (codegen
        ~1254); what's MISSING is a TIME-driven arm. Open design questions:
        reactor-timer-that-re-arms (reuses waitTimer/registerTimer; actor coro
        parks on the timer between fires) vs poll-deadline-in-drain-loop
        (simpler, drift under load). Also: periodic vs one-shot, interaction
        with sends + shutdown, drift. BRAINSTORM before building.
  - [ ] Phase 4: `resp.ok`/`resp.err` future-readiness select arms. OPEN: the
        runtime model (is `resp` a pending future the select awaits vs timeout,
        or already-resolved?) — decide before building. UNCONFIRMED.

## Open Questions
- UNCONFIRMED (Phase 4): resp.ok/resp.err readiness runtime model — pending
  future awaited by the select, or already-resolved branch? User deferred;
  decide at Phase 4 start.
- Do we need `Seconds`/`Microseconds` too, or just `Milliseconds` for now?
  (start with Milliseconds; add others if a phase needs them.)
- `.fn {args}` undeclared-method (copyFrom) — ex16's other blocker; may become
  its own tiny example or fold into a phase.

## Working Set
- std/time.tuck — add distinct unit types + helper fns.
- compiler/parser.nim ~791 parseSelectExpr — the select arm parsing.
- compiler/codegen.nim — select lowering (tuckAwaitReadOrTimeout).
- compiler/tuck_async.nim — the timeout primitive.
- examples/29,30 (retype), new per-phase examples.
- Test: cli_smoke.sh, compile_all_examples, typecheck_tests, beef_backend.
