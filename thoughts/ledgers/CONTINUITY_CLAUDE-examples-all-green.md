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
- Now: [→] Phase 4: alias() restructuring (fixes 18 + 01's silent no-op).
- Remaining:
  - [ ] Phase 3: 04 — `Self` mapping + interface/manager emission + empty
        setMany body indent (`proc setMany(self: Self,...)` invalid Nim).
  - [ ] Phase 4: alias() restructuring lowering (spec 2.5) — fixes 18 AND
        01's silent no-op (semantic!). Checker knows field maps; codegen
        emits tuple rebuild `(id: x.trackId, name: x.title, ...)`.
  - [ ] Phase 5: 03 — bake real specialization (spec 3.5; emits garbage
        `x((someFunc: _add))` today).
  - [ ] Phase 6: 11 — rewrite off removed `or return` to 4.9 policy; needs
        `when TARGET` §8.3 + top-level statements/implicit main.
  - [ ] Phase 6b: 17 — `input` keyword + `merge` (structural merge = future
        language keyword per user). Needs a design ruling first.
  - [ ] Phase 7: 20 — transitionTo-with-payload inside actor handler emits
        `PlayerState.Decoding(transitionTo(self.state))(rate)` garbage;
        register DSL depth (`DAC_CR.EN = true` — MMIO attrs).
  - [ ] Phase 8: 16 — `on select` §9.3 + timeout sugar (`timeout.5s` emits
        invalid case arm). BLOCKED on actor/task runtime strategy ruling
        (nim-cps vs hand-rolled state machines, ROADMAP 2026-07-09).
  - [ ] Phase 9: semantic-equivalence pass — runtime-verify every example
        with a main (extend gate to build+run+assert where feasible).

## Open Questions
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
  cli_smoke.sh (BEEFBUILD_BIN=~/apps/Beef/IDE/dist/BeefBuild), beef_backend
