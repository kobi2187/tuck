# Rule G implementation checkpoint

Date: 2026-10-10. Branch: `docs/verified-feature-status-2026-10-10`.
Direction: finish the approved type glue, then switch ownership mode.
This checkpoint is not a declaration that G or the switch is complete.

## Implemented

- `compiler/ownership_glue.nim`: a memoized graph within each derivation,
  with recursive back edges and least-fixed-point ownership. Handles strings,
  sequences, arrays, records/objects, sum payloads and result/option payloads.
  Generic arguments are instantiated in the caller's environment before
  entering the callee's scope. Alias shapes are resolved after graph construction.
  The uninitialized-field marker erases to its underlying shape, not a result.
- `compiler/ownership_glue_odin.nim`: generates concrete copy/drop/reset
  procedures, memoized by emitted instantiated type in one codegen context.
  Non-owning sequence elements use bulk copy. Owning elements recurse.
  Sums visit the active variant; results visit only an Ok payload.
  Reset drops the owned value and writes an empty value, and is repeatable.
- `compiler/tuckrt_d/tuck_rt.d`: recursive `tuckCopyG`, preserving native GC.
  Mutable arrays and struct fields copy recursively; immutable leaves can share.
  Failure/absence payloads are not traversed. Reference classes and native unions
  require explicit glue rather than silently pretending to be values.
- D emission: explicit copy nodes, borrowing twin wrappers and owning mailbox
  payload copies call `tuckCopyG`. This improves the implementation of existing
  copy decisions; it does not make those decisions complete.

Nim's native copy/destruction behavior and D's collector policy are unchanged.
Odin's production shallow helper is unchanged until the matching copy/drop
placement migration is ready. The temporary sequence-only Odin prototype was
removed after the generated glue subsumed its tests.

## Tests and evidence

`tests/suites/ownership_glue.nim` includes:

- Shared graph shapes: nested sequences, deep records beyond the old depth
  cutoff, arrays, generic records, nested generic substitution, phantom type
  arguments, alias cycles and recursive sum cycles.
- Native D kernel tests: mutation independence of nested arrays in structs,
  fixed arrays and Ok results; inactive result payloads and empty sequences.
- Generated Odin procedures compiled and run with `TUCK_TRACK=true`: nested
  and triple sequences, sequences of records, owned strings, recursive sums,
  arrays, generic inline records, empty buffers, active/inactive results,
  source survival after a copy is dropped, and repeated reset.
- D emission pins for copy nodes, twin wrappers and mailbox payloads.
- An end-to-end nested-sequence result pin on the available Nim/Odin/D backends.

Red tests demonstrated missing D recursive-copy support, incorrect chained
generic substitution and erased-marker shape, and unwired D emission paths.
The implementation was added only after those failures.

Targeted suites passed: `ownership_glue`, `ownership_rules`, `d_backend`,
`value_semantics`, and `complexity`. D backend: 185 assertions; value semantics:
75 assertions. The complexity tool was built locally; its ceiling 20 and heavy
limit 11 were preserved by splitting the new graph/generator routines.

An earlier full run exposed obsolete `.dup` emission expectations and the missing
local complexity tool. Those were corrected and retested with targeted suites.
The final full gate is recorded after it runs; do not infer a clean full run from
the targeted results.

## Remaining G integration, in dependency order

- **Typed ownership places:** retain the resolved type on scope-end and parameter
  drop nodes. A path string alone cannot select generated glue. Test local,
  parameter, record-path and instantiated generic types before changing emission.
- **Static-string ownership:** clone borrowed/static strings at owning sinks,
  including record fields, sequence elements and variant/result payloads.
  A deep drop must never free a literal. Keep these tests allocation-tracked.
- **Shared slots and partial moves:** replace direct-Seq-field-only slot discovery
  with the graph's owning paths. Preserve path granularity for a moved field,
  nested overwrites and reset. Update elaborator and independent checker together.
- **Atomic Odin activation:** pair generated copy and deep drop at all existing
  explicit nodes, overwrite sites, wrappers and mailbox transfers in opt-in
  rules mode. Never activate just one half.
- **Generalize remaining copy decisions:** nested owning records, arrays,
  result/sum payloads and generic instances must not disappear from classification.
  D's new copy operation cannot fix a missing copy node.
- **Acceptance before default switch:** tracked G regressions including A39,
  A41-A45; independent verifier; three-backend equivalent results; relevant
  ownership/container/tree benchmarks; then the end-of-session full test gate.
  Only then change the default and remove obsolete machinery in verified steps.

Imported type identity, anonymous/parameterized payload sums and any checker-side
types that should have been erased need end-to-end coverage before claiming
universal glue support. Resource-handle policy and selectable memory reclamation
remain separate, deferred work.

## Fast iteration

Use `./tests/run ownership_glue --quiet --jobs:4` while working on the graph or
copy kernels. Add `ownership_rules` and `value_semantics` for ownership-tree
changes, `d_backend` for D emission, and `complexity` for new compiler helpers.
Use `./tests/run --quiet --jobs:8` only at the end-of-session gate.
