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

## State — COMPLETE for this pass (2026-07-11)
- [x] Phase 1: Expr.ty stamped in synthesize wrapper; pipeline shares refs.
- [x] Phase 2: explodeRecordArg in genCall + genConstruction; `p advance` →
      advance(p.position, p.step), runtime-verified, cli_smoke regression.
      Root-caused: constructions synthesized Unknown — now typed. Also fixed
      latent written-order arg bug in genConstruction struct path. 096da30.
- [x] Phase 3: generic construction — checker infers bindings from payload,
      ty stamp carries tkApp; codegen emits Box[int](...). Uninferrable
      param = clear error. Runtime-verified.
- [~] Phase 4 findings: mutation validate blocked on `..` emission DESIGN
      (setter-call convention `x.field(arg)` — needs user ruling on mutation
      lowering), not on type info. Ex 04/12 = sketch decl edits only;
      ex 18 = alias() restructuring (separate feature). Gate unchanged 14/25.
- Ceilings: non-exkVar payload args not exploded (double-eval; bind-to-temp
  when needed); cross-module explosion (qualified callee) not attempted.

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
