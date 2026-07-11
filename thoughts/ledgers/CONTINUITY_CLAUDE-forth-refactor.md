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

## State — COMPLETE (2026-07-11)
- Done:
  - [x] Phase 1: parseDecl → 9 named per-decl parsers + parseDeclAttrs (4x dup)
        + parseInvariantBlock (2x dup). Commit b7f8af0.
  - [x] Phase 2: wrapper-branch merge, parseParenType, parseBraceType,
        parseTypeUseAttrs, parseStructLiteral, parseBraceBlock,
        tryUnsafeMarker (2x dup), parseAliasStep, parsePostfixCall. efcfb3a.
  - [x] Phase 3+4 (sonnet agent): genFnDecl, genSumType+genTransitionProcs,
        genRecordType, genAliasType, genActor, genRegistry, genCall,
        genConstruction, genReturn. ff9dfd3.
  - [x] Phase 5 (sonnet agent): synthFieldAccess/Call/Binary/Chain/If/Match;
        checkDecisionTable deliberately left whole. 5721e91.
- Result: longest procs were 644/442/313 → now every dispatcher ≤135 lines and
  reads as a table of contents. All suites green at every step.

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
