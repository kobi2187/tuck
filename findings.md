# Findings

## Session 2026-07-05 (type checker)
- Parser erased let/var distinction — both parsed to bare `exkAssign`. Spec §2.3
  (`..` only on var) unenforceable without it. Fixed: `isDecl`/`isMutable` flags.
- `fn f({a: int, b: int})` parses to FLAT params [a: int, b: int]; call sites pass
  one struct arg whose fields map to params by name → subset matching lives in
  `checkCallArgs` (typecheck.nim).
- `!T`/`?T`/`!?T` parse as tkApp with tkNamed base "!"/"?"/"!?" — unwrap before
  return-type comparison.
- `lowering.getFieldsForType` resolves tkNamed/tkUnion/tkRename → field list;
  exported and reused by checker.
- Checker caught real spec violation on first run: examples/17-input-merge.tuck
  mutated a `let ctx` with `..`. Fixed to `var`.
- Pre-existing (NOT this task): 18/20 generated .nim outputs fail `nim check`
  (f32/u2/u12 unmapped in genType, `.ms` unit sugar unlowered, registry emit
  produces invalid Nim indentation). Test harness never runs `nim check` —
  "Successfully compiled 20 examples" only means AST→string emission succeeded.
- No git repo. No AGENTS.md/VISION.md etc.

## Open design decisions (user to rule)
- **Empty init / no defaults** (raised 2026-07-05): spec already has the
  "invisible option" — `?T` (one char), `or` for defaults, no nil (Appendix B).
  NOT specified: what `Foo {}` (empty construction) means. Options:
  (a) compile error — every field required at construction; absence must be
  explicit `?T` (recommended: matches no-defaults, nothing invisible);
  (b) empty construction implicitly produces `?Foo`.
  Decide + add to spec §4.8 when settled.

## Spec deltas (spec §11 vs reality)
Spec claims npeg parser + flat IR + Merkle cache; reality is recursive-descent
parser + ref-AST + no cache. Checker deliberately built on reality.
