# TASKS

The near-term slice. Every task traces to a node in `ROADMAP-GRAPH.md` (the
map) and is sized to fit one agent's working context — description, interfaces
and acceptance criteria under ~2–3k tokens, ideally one file.

**The last acceptance criterion on every task is mandatory** — "no changes
outside these files" is the cheapest drift detector there is.

Not a replacement for the hole list: once `holeOpen`/`holeFilled` exists (T-01),
each unfilled map node becomes a hole, and TASKS.md holds only what is actually
in flight.

Status: `pending` · `in-progress` · `review` · `done` · `escalated`

---

## T-01: `holeOpen` / `holeFilled` in the harness
Status: pending
Maps to: §11 skeleton process
Depends on: —
Interfaces: mirror `bugOpen`/`bugFixed` at `tests/harness.nim:425-439` exactly
Acceptance criteria:
- [ ] `holeOpen` reports OPEN rather than failing; prints `NOW PASSING — flip it` when the assertion starts passing
- [ ] `holeFilled` is a permanent regression guard
- [ ] one real hole declared as a smoke test (suggest `F6 volatile MMIO`)
- [ ] no changes outside `tests/harness.nim`, `tests/suites/holes.nim`, `tests/suites/all.nim`

## T-02: pin the hole count in `end_to_end.nim`
Status: pending
Maps to: §11
Depends on: T-01
Interfaces: the existing bug-count check at `tests/suites/end_to_end.nim:186-200`
Acceptance criteria:
- [ ] hole count in `ROADMAP.md` is machine-checked against the suite
- [ ] closing a hole without updating the doc fails the suite
- [ ] no changes outside `tests/suites/end_to_end.nim`, `ROADMAP.md`

## T-03: fix `std/time`'s self-collision
Status: pending
Maps to: §3 stdlib tier — **DISCOVERIES D-07**
Depends on: —
Interfaces: `std/time.tuck` — `nowMs() -> {ms: u64}` vs `fn ms(value: u32)`
Acceptance criteria:
- [ ] `nowMs` result field renamed (suggest `millis`) so `.ms` no longer collides, OR the fn renamed — pick one and say why in the module comment
- [ ] a test asserts elapsed-time arithmetic checks clean
- [ ] no changes outside `std/time.tuck`, `tests/suites/stdlib.nim`

## T-04: `--version` and `--help` before the file check
Status: pending
Maps to: §9 R0 · C10
Depends on: —
Interfaces: `tuck.nim:265-278`, the flat `case cmd` at `tuck.nim:330`
Acceptance criteria:
- [ ] `tuck --version` prints a version; `tuck -h` prints usage; neither requires a file argument
- [ ] version derived at compile time, not hardcoded in two places
- [ ] no changes outside `tuck.nim`, `tests/suites/cli_smoke.nim`

## T-05: `TUCK_RUNTIME` for the three `getAppDir()` sites
Status: pending
Maps to: **F22** · C10 · C11
Depends on: —
Interfaces: `tuck.nim:352, 420, 483`; `TUCK_STDLIB` already exists in `modules.nim:279-292`
Acceptance criteria:
- [ ] runtime path resolves from `TUCK_RUNTIME` when set, `getAppDir()` otherwise
- [ ] the hardcoded `/home/kl/apps/Odin/odin` at `tuck.nim:553` replaced by `TUCK_ODIN` + `findExe`
- [ ] a test builds with the binary invoked from outside the source tree
- [ ] no changes outside `tuck.nim`, `tests/suites/cli_smoke.nim`

## T-06: `install.sh` + a relocatable emitted import
Status: pending
Maps to: **F22** · **F13** (partial)
Depends on: T-05
Interfaces: emitted `import ../compiler/tuck_rt` — a source-tree path baked into every artifact
Acceptance criteria:
- [ ] `install.sh PREFIX` copies `tuck`, `std/`, `compiler/tuck_*.nim`, `compiler/tuckrt/` and writes a wrapper exporting the two vars
- [ ] emitted `.nim` compiles from a directory with no relationship to the checkout
- [ ] no changes outside `install.sh`, `compiler/codegen.nim`, `compiler/codegen_odin.nim`, `tests/suites/cli_smoke.nim`

## T-07: `tuck test` v0
Status: pending
Maps to: **C7**
Depends on: T-04
Interfaces: one new `of` arm in the `case cmd` at `tuck.nim:330`; reuses the existing build path
Acceptance criteria:
- [ ] `tuck test [dir]` builds and runs every `*_test.tuck`; nonzero exit is a failure
- [ ] summary reuses the `report()` shape at `tuck.nim:248-252`
- [ ] **zero compiler changes** — CLI only
- [ ] no changes outside `tuck.nim`, `tests/suites/cli_smoke.nim`

## T-08: `alloc` and `resource` into the lexer attribute table
Status: pending
Maps to: **F9** — gates F10, which gates F11
Depends on: —
Interfaces: `lexer.nim:152-158`; spec §3.7 names `alloc`, §7.4 names `[resource: udp]`
Acceptance criteria:
- [ ] `[no_alloc]` and `[resource: udp]` both parse
- [ ] an unknown attribute is still strict-rejected (do not weaken `parseEffectList`)
- [ ] a test asserts each parses and reaches the AST
- [ ] no changes outside `lexer.nim`, `compiler/parser_type.nim`, `tests/suites/effects.nim`

## T-09: keep `[stack: N]`'s N in the AST
Status: pending
Maps to: **F12**
Depends on: T-08
Interfaces: `parser_type.nim:196` `harvestEffects` — maps `"stack"` to a bare `emStack`, drops `.value`
Acceptance criteria:
- [ ] the declared budget survives to the AST (same for `[priority: N]`)
- [ ] `tuck p --ast` shows the value
- [ ] no analysis yet — carrying the number is the whole task
- [ ] no changes outside `compiler/parser_type.nim`, `compiler/ast.nim`, `tests/suites/effects.nim`

## T-10: one shared error renderer
Status: pending
Maps to: §9 R1 — **DISCOVERIES D-04, D-05**
Depends on: —
Interfaces: `dieSyntax` at `tuck.nim:88-107` is the target shape; `SemanticError` at `semantics.nim:34-35` gains `file`, `code`, `endCol`
Acceptance criteria:
- [ ] type errors render with snippet + caret, like parse errors do today
- [ ] **position printed exactly once** — fix the `typecheck_util.nim:57` / `typecheck.nim:3491` double
- [ ] footer points at `tuck explain`; `tuck explain` with no argument lists codes by category
- [ ] no changes outside `tuck.nim`, `compiler/semantics.nim`, `compiler/typecheck_util.nim`, `tests/suites/diagnostics.nim`

## T-11: the jam papercuts — decide, then fix or document
Status: pending
Maps to: **C11** — DISCOVERIES D-01, D-02, D-03
Depends on: —
Interfaces: parser only
Acceptance criteria:
- [ ] multi-line list literals parse (D-01), or the ceiling is stated in `LANGUAGE-OVERVIEW.md` §0
- [ ] value-`if` composes as a binary operand (D-02), or same
- [ ] bare-receiver postfix inside a struct literal (D-03), or same
- [ ] **each of the three gets a decision recorded, not silence** — a ruling is an acceptable outcome
- [ ] no changes outside `compiler/parser*.nim`, `LANGUAGE-OVERVIEW.md`, `tests/suites/parser.nim`

## T-12: examples must compile their emitted Nim
Status: pending
Maps to: **C11** — DISCOVERIES D-08, D-09
Depends on: —
Interfaces: `tests/suites/examples.nim` runs `tuck c` only; nothing ever compiles the emitted Nim
Acceptance criteria:
- [ ] the examples suite compiles emitted Nim for every example (gated on the run mode, not `--check`)
- [ ] `20-embedded-mp3-player` is expected to fail today — declare it a `holeOpen`, do not delete it
- [ ] no changes outside `tests/suites/examples.nim`, `tests/suites/holes.nim`

---

## Escalation ladder (per task)

1. fast-tier impl fails review → **one** retry with the reviewer's specific feedback appended
2. second failure → mid tier implements it
3. mid tier stuck, or the failure implies an interface/architecture problem → frontier reviews **that one task + its map node**, and decides: fix in place, re-spec, or descope

Never re-run the pipeline because one task failed. Never let a fast-tier agent
retry more than once.
