---
date: 2026-07-11T19:59:45+03:00
session_name: type-directed-lowering
researcher: Kobi
git_commit: f0928cd
branch: main
repository: tuck_lexer
topic: "Resource registry design, generics v1, invariants, forth refactor, type-directed lowering"
tags: [implementation, tuck, generics, invariants, refactor, typed-ast, lowering, resources]
status: complete
last_updated: 2026-07-11
last_updated_by: Kobi
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: type-directed lowering landed (typed AST) + generics v1 + invariants + forth refactor + §7.4 resource design

## Task(s)
All COMPLETED this session, in order:
1. **Spec §7.4 resource registry** (docs only, 6f6f064): global per-kind slot
   registry design settled with user — full rulings in ROADMAP + spec §7.4.
   Implementation = ROADMAP Missing entry, not started.
2. **Generics v1** (eb2d3c6): simple substitution, Nim/C# style. Tuck does NOT
   monomorphize — codegen emits `proc f*[T]` / `type Box*[T]`, Nim instantiates.
3. **Invariants block-only** (9acb8ac) + **auto-insert validate()** (2b9cc0e):
   construction + return sites; `when not defined(release)` strips.
4. **Forth-style refactor** (b7f8af0, efcfb3a, ff9dfd3, 5721e91): parseDecl/
   genDecl/synthesize are now small dispatchers over named helpers. codegen +
   typecheck halves done by sonnet subagents, verified by me.
5. **Type-directed lowering** (096da30, f0928cd): Expr.ty typed AST;
   `p advance` → `advance(p.position, p.step)`; generic record construction
   `Box[int](value: 41)` works end-to-end.

## Critical References
- ROADMAP.md — feature matrix + ALL user rulings (resource registry section new)
- thoughts/ledgers/CONTINUITY_CLAUDE-type-directed-lowering.md — ceilings + findings
- tuck-spec.md §7.4 (resources), §4.7 (invariants), Appendix A item 1 (generics model)

## Recent changes
- compiler/ast.nim: Expr gained `ty*: Type` (checker stamp); `fnGenerics` on
  dkFn; SigInfo gained `generics`; UnknownName const moved here.
- compiler/typecheck.nim: synthesize = wrapper stamping e.ty over
  synthesizeKind (typecheck.nim:~630); synthCall types constructions
  (declared type name) and infers generic-construction bindings; FnSig carries
  generics; inferBindings/substituteType; per-expr synth* helpers.
- compiler/codegen.nim: imports lowering; explodeRecordArg + recordFieldNames
  (codegen.nim:~165-188); genConstruction emits `Box[int](...)` from ty stamp
  + param-order struct matching (was written-order — latent bug fixed);
  validate() insertion at construction (tuckInv temps) + plain returns
  (ctx.retInvName); per-kind gen* helpers.
- compiler/parser.nim: parseDecl dispatches to 9 parseXxxDecl procs;
  parseDeclAttrs (killed 4x dup), parseInvariantBlock (2x), tryUnsafeMarker
  (2x); fn/type generic-param brackets (`type Box[T]` disambiguated from attrs
  by Uppercase-first ident); inline/attr invariant forms = parse errors.
- tests/: typecheck_tests +9 generics cases; cli_smoke + invariant runtime
  cases + explosion regression (`advance(p.position, p.step)` grep + run).
- examples/10,15,20 + end_to_end embedded source: invariant block form.

## Learnings
- **Constructions synthesized Unknown** until this session — root cause of the
  explosion probe failing. Now `{...} TypeName` types as its decl. Any future
  "ty is Unknown where it shouldn't be" — check synthCall branch order first
  (typeDecls check sits before fnSigs check, after typeGenerics).
- **genConstruction emitted struct-literal args in WRITTEN order** (latent
  arg-swap bug); lowering.nim's lowerExpr ALSO rewrites struct-literal call
  args positionally at its own layer — two places do payload explosion, watch
  for divergence.
- `..` mutation emission is a setter-call convention `x.field(arg)` that
  mostly can't compile — mutation-site invariant validate is blocked on a
  DESIGN ruling (what does mutation lower to?), not on type info.
- Duplicate forward decl of same proc = Nim error "implementation expected".
- reportError quits (no exception) — parse errors untestable via
  typecheck_tests harness; use cli_smoke for those.
- msgpack cache: build stamp invalidates on compiler rebuild, so new AST
  fields (ty, fnGenerics) are safe; ast_serializer.nim is JSON debug only.
- Tasks tool wiped between sessions — ledgers + progress.md are the durable
  state (confirmed again).

## Post-Mortem (Required for Artifact Index)

### What Worked
- Forth refactor FIRST, features after: e.ty stamping needed exactly one edit
  because synthesize was already a clean wrapper point. Sequencing paid off
  same-day.
- Probe-driven debugging: tiny .tuck program + one stderr DBG line in
  explodeRecordArg found "ty=set but Unknown" in one iteration.
- Sonnet subagents for parallel per-file extraction refactors (codegen,
  typecheck) while main thread did parser — zero conflicts (disjoint files),
  both verified clean. Compile-check-only instruction avoided test-binary
  races; main thread ran the full matrix once at the end.
- python3 heredoc for bulk code motion (region cut + reinsert) where Edit
  anchors would be unwieldy; Edit for surgical changes.

### What Failed
- Tried: explosion with ty stamp alone → failed because constructions
  synthesized Unknown → fixed in synthCall (construction returns decl type).
- Tried: helper insertion before parseDecl → Nim undeclared-routine error
  (object-body parser at line ~775 uses it) → moved helpers up next to
  forward decls.
- python move left a stray duplicate `proc genExpr` forward decl →
  "implementation of 'genExpr' expected" → removed dup.
- Commit message with backticks in double-quoted bash → command substitution
  ate `when not defined(release)` → amended with single quotes.

### Key Decisions
- Typed AST via in-place `ty` stamp, NO separate semantic-analysis object
  (user asked): ref-AST has no stable node IDs (side table breaks across
  msgpack reload); TypeChecker already is the transient analysis state.
  Revisit at LSP/flat-IR time.
- Explosion limited to exkVar args (double-evaluation guard); bind-to-temp
  lowering deferred until a real case.
- Generics: no Tuck monomorphization — Nim does it. Generic fn bodies gradual
  (T binds Unknown), call sites strictly inferred.
- checkDecisionTable left unsplit in refactor: two self-contained algorithms,
  splitting = indirection not clarity.
- Resource registry (user rulings): kinds user-declared via `resources:`
  block; `[resource: kind]` attr rides effects propagation; defer = mark
  isFinished + on_finish + generation bump AT MARK; strict/lazy/exit policies;
  sweep INLINE in defer-release code at watermark, `sweep_batch: N`; NO
  refcount, NO time-based eviction; cap optional (seq unbounded / static
  array on standalone).

## Artifacts
- tuck-spec.md §7.4 (new), §4.7 (rewritten), §4.6 attr list, Appendix A items
- ROADMAP.md (rulings 2026-07-11 ×2 sections; Partial/Missing rows updated)
- progress.md (5 dated entries for this session)
- thoughts/ledgers/CONTINUITY_CLAUDE-forth-refactor.md (complete)
- thoughts/ledgers/CONTINUITY_CLAUDE-type-directed-lowering.md (complete, has ceilings)
- compiler/{ast,parser,typecheck,codegen}.nim, tests/{typecheck_tests.nim,cli_smoke.sh,end_to_end.nim}
- examples/{10,15,20}*.tuck
- Commits: 6f6f064, eb2d3c6, 9acb8ac, 2b9cc0e, b7f8af0, efcfb3a, ff9dfd3,
  5721e91, 867b6c0, 096da30, f0928cd

## Action Items & Next Steps
1. **Tutorial** (the standing deliverable from previous handoff) — now truly
   unblocked: `p advance` fluent style works. Staged app under tutorial/
   teaching VISION.md process; rewrite TUTORIAL.md. Decide `mixin` keyword
   fate from the examples.
2. **`..` mutation lowering ruling** (user decision needed): what does
   `x ..field {v}` emit? Unblocks mutation-site invariant validate.
3. **alias() restructuring** (spec 2.5) — unblocks example 18.
4. Example edits only: 04/12 need sketch decls (Config, Feed) to enter the
   nim-check gate.
5. Resource registry §7.4 implementation (parser/checker/rt/codegen/report) —
   design fully settled, build items in ROADMAP Missing.
6. Suites: typecheck_tests (78), compile_all_examples (gate 14/25), 
   cli_smoke.sh, end_to_end. Wipe .tuck-cache dirs after compiler changes.

## Other Notes
- Explosion ceilings: non-exkVar args, cross-module qualified callees — noted
  in type-directed-lowering ledger.
- Generic fns can't construct generic records of a DIFFERENT type param yet
  (binding uninferrable inside gradual bodies) — error message guides.
- Standing user prefs: caveman+ponytail modes active; commit freely, no
  Claude attribution (though harness may append one — earlier commits this
  session are clean); nim skills live in ~/.agents/skills/.
