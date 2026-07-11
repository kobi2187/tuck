# Continuity: type-directed-lowering

## Goal
Codegen stops being type-blind: checker annotates every Expr with its type
(`ty` field), codegen reads it. Done = `p advance` emits `advance(p.position,
p.step)`; generic record construction works (`Box[int](...)`); mutation-site
invariant validate fires; examples 18/04/12 pass the nim-check gate (or their
remaining blockers are named).

## Constraints
- Checker is the single source of type truth; codegen only READS e.ty.
- Pipeline must run typecheck BEFORE codegen on the SAME AST refs (verify in
  tuck.nim + tests). Lowering-created synthetic nodes: copy ty from source
  node where meaningful, else nil (codegen falls back to current behavior).
- Fallback everywhere: e.ty == nil → today's emission. Never regress a
  passing example.
- Suites after every phase; commit per phase.

## Key Decisions
- Annotate in synthesize dispatcher (one place, post-forth-refactor).
- Unknown type stays nil-equivalent for codegen (don't explode Unknowns).

## State
- Now: [→] Phase 1: ty field + stamping + pipeline verify
- Remaining:
  - [ ] Phase 2: record-var call explosion (genCall/genConstruction)
  - [ ] Phase 3: generic record construction (drop v1 checker error)
  - [ ] Phase 4: mutation-site validate; examples 18/04/12 → gate attempt
  - [ ] Docs: ROADMAP (Partial rows: alias lowering, invariants), progress.md

## Open Questions
- UNCONFIRMED: does `tuck check` (no codegen) path share TypeChecker AST with
  compile path? (It re-parses per command — each command runs its own
  pipeline, so fine.)
- alias() restructuring (spec 2.5) — separate follow-up; not in this pass.

## Working Set
- compiler/ast.nim (Expr.ty), compiler/typecheck.nim (synthesize stamp),
  compiler/codegen.nim (genCall/genConstruction/chain), tuck.nim (order),
  examples/{04,12,18}, tests/*
- Test: full matrix (see forth-refactor ledger)
