# Task Plan: Bidirectional Type Checker (synth + check, fail-fast)

Full plan: /home/kl/.claude/plans/describe-the-goal-impl-validated-music.md

## Decisions
- Unknown type for undeclared symbols (gradual — sketch examples keep compiling)
- Abort on first error (SemanticError with span)
- Core scope only: shapes, subset call matching, returns, let/var, `..`-on-var rule
- Works on existing ref-AST; no flat IR

## Phases
- [x] Phase 1: AST/parser — carry let/var distinction (`isDecl`/`isMutable` on exkAssign)
- [x] Phase 2: compiler/typecheck.nim — synthesize/check/compatible/collectSigs
- [x] Phase 3: Wire into pipelines (before lowering) + tests/typecheck_tests.nim
- [x] Phase 4: Verify — 12/12 typecheck tests, 20/20 examples, end_to_end green

## Out of scope (v1)
Match exhaustiveness, distinct/unit types, generics substitution, flat IR,
fixing the 18 codegen `nim check` failures (separate task).
