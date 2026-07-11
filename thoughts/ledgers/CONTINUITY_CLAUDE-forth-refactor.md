# Continuity: forth-refactor

## Goal
Compiler readable top-down: every dispatcher (parseDecl, genDecl, synthesize)
reads as a table of contents of small named helpers ("forth style" — many tiny
words composing upward). Zero behavior change. Done = all phases checked, all
suites green, no proc over ~80 lines in the refactored files.

## Constraints
- Extraction only — no semantic changes, no renames of public API.
- Nim skills loaded (~/.agents/skills/): top-level helper procs, explicit
  `var Parser`/`var CodegenCtx`/`var TypeChecker` state params, narrow exports
  (helpers stay private), stdlib naming, 2-space indent, no tabs.
- Suites after EVERY phase: tests/typecheck_tests.nim,
  tests/compile_all_examples.nim, tests/cli_smoke.sh, tests/end_to_end.nim.
  Wipe .tuck-cache dirs before suites.
- Commit per phase (user has standing OK; no Claude attribution).

## Key Decisions
- Helper naming: parseXxxDecl / genXxx / synthXxx — dispatcher case arms become
  one-line delegations.
- Helpers private (no *) unless already exported.
- Forward decls where extraction breaks def-before-use order.

## State
- Done: (none yet)
- Now: [→] Phase 1: parser.nim parseDecl → per-decl-kind procs (644 lines)
- Remaining:
  - [ ] Phase 2: parser.nim parsePrimaryType/parseChainExpr/parsePrimaryExpr helpers
  - [ ] Phase 3: codegen.nim genDecl → per-kind emitters (442 lines)
  - [ ] Phase 4: codegen.nim genExpr overloads → site helpers
  - [ ] Phase 5: typecheck.nim synthesize → per-expr-kind procs (313 lines)

## Open Questions
- UNCONFIRMED: whether parser Parser object methods use `var Parser` uniformly
  (check while extracting).

## Working Set
- Files: compiler/parser.nim (1571), compiler/codegen.nim (1023),
  compiler/typecheck.nim (994)
- Branch: main
- Test: nim c -r --hints:off --warnings:off tests/typecheck_tests.nim &&
  nim c -r --hints:off --warnings:off tests/compile_all_examples.nim &&
  bash tests/cli_smoke.sh && nim c -r --hints:off --warnings:off tests/end_to_end.nim
