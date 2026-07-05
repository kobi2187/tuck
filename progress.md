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

## 2026-07-05 (later still) — emitter fixes round 2
- `...` pending holes emit `discard` (was verbatim `...` — invalid Nim).
- Inline sum-type fields hoisted to named enums (`<Parent><Field>Kind`) via
  `CodegenCtx.hoisted` accumulator, prepended in emitNim (fixed m08).
- Actor with zero handlers emits bare state object (empty enum invalid; m15).
- Actor handler params now ride the message envelope: fields deduped by name,
  `let p = msg.p` prelude per dispatch arm, typed send helpers (fixed m05).
- Parser: attr allowlist extended with big_endian/little_endian/volatile/
  wrapping/trapping — `u16 [big_endian]` no longer misparsed as generics (m15).
- nim-check gate now 7/20: 05, 06, 08, 10, 13, 15, 19.

Next candidates:
1. Type-directed lowering: expand record-typed vars at call sites + real alias
   restructuring (blocks m18; needs typechecker info flowing into lowering).
2. `pending:` blocks with typed signatures → stubs for sketch symbols (fetch,
   Feed...) → most remaining examples could go green.
3. `on select` lowering to task state machines (spec 9.2; blocks m14, m16).
4. Top-level `or return` semantics — implicit main? (blocks m11).
5. Extend checker: match exhaustiveness, distinct/unit types, generics.
