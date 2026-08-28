# Stage boundary crossings in codegen

**Rule (user, 2026-08-27).** Each stage owns one concern. A question asked at
EMIT time means an earlier stage did not finish its job. A single exception is
fine; machinery for another stage's concern means the design is wrong — fix
the boundary, do not make the workaround faster.

## The two kinds of emit-time query

**Legitimate — reading a fact an earlier stage RECORDED** (table lookup):
`semLayer.typeFor` / `call` / `hasCall` / `stepCall` / `argFieldsFor` /
`callParamsFor` / `shortcut` / `wrapOf`.

**Violation — RE-DERIVING a fact by scanning the decl list:**
`getFieldsForType`, `lookupFnParams`, `recordFieldNames`, `declaresFn`,
`findFn`, `findDecl`, `isRecordType`, `hasInvariants`, `saturatingType`,
`externInvRet`, `externEmitName`, `enumTagOwner`, `satisfiersOf`,
`payloadSumVariant`.

Counted 2026-08-27: **codegen.nim 38, codegen_odin.nim 30, codegen_d.nim 22**.

## Findings, in dependency order

- [ ] **F1. `declForType` is never recorded for INFERRED types.**
  `getFieldsForType` prefers the checker's edge and falls back to a decl
  scan. Instrumented: the edge misses 100% (200 misses for 200 types), and
  the missing Type nodes report `hasId=false` — they are checker-synthesized
  types for expressions, which never pass through `resolveTypeNames` (that
  pass only walks types MENTIONED IN DECLARATIONS).
  *Effect:* every field lookup at emit is a full module scan → emit is
  quadratic in every backend (D's share: 0.03s / 0.11s / 0.38s at
  200 / 500 / 1000 types; Nim the same curve, smaller constant).
  *Fix:* resolve the type edge where the checker stamps an expression type.
  *ATTEMPTED 2026-08-27, did not land.* Added
  `typecheck.resolveInferredTypes` (walks `semLayer.allTypes()` after
  checking, resolving every tkNamed) plus a `Resolution.allTypes` iterator.
  It runs and resolves 400 named types on the 200-type probe — but the
  misses stay at 200 and the timing is unchanged. Minimal repro
  (`type R = {a: int}` + `let v = {a: 5} R`) shows the missing node as
  `MISS R id=unset kind=tkNamed`: the Type object lowering asks about was
  never in the checker's table at all, so it has no id and no edge. It is
  minted after checking — by lowering itself or by the per-backend deepCopy.
  NEXT STEP is to find where that node is created, not to add another pass;
  the pass is kept because it is correct and cheap, but it is not sufficient
  alone. `Type` does inherit `Node.id` and ast.nim's comment says giving
  Type identity was exactly so these scans could become table reads — so the
  design intends this to work.

- [ ] **F2. `callParamsFor` unrecorded for three categories** — pending fns,
  distinct-type ctors (`5 Milliseconds`), combinators (`alias`). All three
  backends therefore keep a `lookupFnParams` decl-scan fallback
  (`expectedParamNames` x3, `payloadFieldArg` x3, `explodeRecordArg` x3,
  ~150 lines). *Fix:* record the mapping for those cases at the checker.

- [ ] **F3. `s.len` types as `<unknown>`** — a FAILED stamp, not a missing
  one. The D backend hardcodes `int` (what the language guarantees). Nim
  hides it by emitting `var n = s.len` and letting Nim infer.
  *Fix:* stamp it in the checker. Possibly a genuine single exception
  rather than machinery — decide when F1 is done.

- [ ] **F4. Decl-shape queries** (`isRecordType`, `hasInvariants`,
  `saturatingType`, `externInvRet`, `externEmitName`, `enumTagOwner`,
  `satisfiersOf`, `payloadSumVariant`) are answered per-node by scanning.
  Nim had six private `*Fast` procs over a private index;
  `compiler/decl_index.nim` now shares that shape.
  *NOTE — this may be the wrong fix.* An index makes emit-time re-derivation
  cheap instead of removing it. Measured gain was 0.84s -> 0.80s, i.e. these
  were not the hot queries. **Re-evaluate after F1/F2: if the scans are gone,
  delete decl_index.nim rather than keep a cache for work that no longer
  happens.**

## Order of work
1. F1 (measurable target: the quadratic term disappears)
2. F2 (then `delete-symbol` the three backends' fallbacks — its
   refuses-if-referenced is the proof they are dead)
3. F3 (decide: bug or genuine exception)
4. F4 (re-evaluate; likely delete)
