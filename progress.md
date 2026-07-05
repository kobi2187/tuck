# Progress Log

## 2026-07-05
- Assessed project: lexer/parser solid, semantics = effects only, codegen unverified.
- Implemented bidirectional type checker: compiler/typecheck.nim (~370 lines).
  - Pass 1: collectSigs (fns, tasks, types, nested in objects/mixins/actors).
  - Pass 2: synthesize/check per decl; fail-fast SemanticError with span.
  - Rules live: subset matching, missing/wrong-typed call fields, return type,
    field-access on known records, arithmetic/comparison clashes, `..` on let,
    numeric-group widening, Unknown propagation for undeclared symbols.
- AST/parser: exkAssign now carries isDecl/isMutable.
- lowering.nim: exported getFieldsForType.
- Tests: tests/typecheck_tests.nim (7 negative + 5 positive) — all pass.
  compile_all_examples 20/20; end_to_end unchanged + effect test still passes.
- Fixed examples/17-input-merge.tuck (let→var, real violation found by checker).

## 2026-07-05 (later) — verification loop + codegen fixes
- git init (branch main) + .gitignore for build artifacts.
- codegen.nim fixes: str/f32/f64/usize/Seq/Array/fn type mappings, uN/iN bit-width
  rounding (u2→uint8, u12→uint16), `%`→`mod`, unit sugar (5.ms → 5), !T/?T wrapper
  erasure in genType, registry: consistent field indent + forward decls for handlers.
- compile_all_examples now runs `nim check` on generated Nim; expected-pass gate:
  06-transitions, 10-invariants, 13-arena-mem, 19-event-registry (4/20).
  Remaining 16 fail ONLY on sketch-inherent undeclared identifiers (fetch, merge,
  Feed, Action...) — need stubs/pending support to go green.
- All suites green: typecheck 12/12, examples 20/20 + nim-check gate, end_to_end.

Next candidates:
1. Stub/pending support so more examples emit self-contained Nim → grow gate list.
2. Extend checker: match exhaustiveness, distinct/unit types, generics.
3. Actor/emitter indentation bugs (m05, m08, m15, m18 invalid Nim blocks).
