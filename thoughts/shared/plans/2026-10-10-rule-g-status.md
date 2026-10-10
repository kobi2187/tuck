# Rule G implementation checkpoint

Date: 2026-10-10. Branch: `docs/verified-feature-status-2026-10-10`.
The Glue integration and default switch are implemented and functionally gated.
The end-of-session full gate passed all non-complexity suites; the explicitly
deferred complexity gate remains failing, with its thresholds unchanged.

## Architecture and default

The owner's boundary is implemented: ownership runs on the **common lowered
AST, before backend cloning**. Representation lowering first makes recursive
edges finite and expands composition. The common pass then records:

- Consuming parameters, inferred to a least fixed point.
- `exkCopy` with whole-value `cpValue`, and explicit `exkMove`.
- Typed `exkDrop`, scope-end defers, and drop-before-overwrite metadata.
- `exkReset` for conditional transfers, with nested owning paths preserved.
- Owning-element replacement metadata for indexed writes.

Independent rule V checks this tree before emission and rejects findings in
default mode. A backend then receives a deep copy. Only target adaptation follows:
impl paths, native string-growth specialization, and emission/runtime operations.
The default is rules mode without an environment flag; `TUCK_OWN=rules` still
selects it explicitly. `TUCK_OWN=legacy` retains the historical compiler path
for differential tests, not a separately supported runtime profile.

This fixes a real clone-boundary problem: semantic resolution contains references
to original declarations and operands, not only node-id lookups. Clone-first
ownership could inspect stale, unelaborated callees and miss shared operands.
Three subprocess tests assert that the original common tree contains copy/move
and typed drops before Nim, Odin or D receives its private clone.

Record update/alias/merge reconstruction and record-as-call-payload projection
now happen here too, not in target renderers. Ownership sees individual field
sinks and unused fields remain owned. Computed receivers are named exactly once;
earlier value operands retain their order, and branch, short-circuit, match and
loop evaluation remain conditional or repeated as the source requires.

## Glue and lifecycle integration

- **Type graph:** recursive back edges, alias resolution, fixed-point ownership,
  strings, sequences, arrays, nested records/objects, sums and result payloads.
  Generic signatures are canonicalized for ownership without changing their
  public backend types.
- **Odin:** generated recursive copy/drop/reset procedures. Concrete shapes use
  type-derived operations; unresolved polymorphic leaves use a recursive runtime
  fallback. Active sum variants and Ok result payloads alone are traversed.
  Static strings are cloned at owning sinks; scoped drops never free literals.
- **D:** deep array/record copies, with an emitted active-arm copy hook for tagged
  sums. Inactive result payloads are cleared, not traversed. Native GC remains.
- **Nim:** native copy/destruction remains. Consuming function parameters use
  the common convention. Semantic drops do not emit empty defer blocks.
- **Tasks and messages:** task bodies and both handler syntaxes are included.
  Task argument/result ownership, local cleanup, mailbox transfer and rejected
  drop-policy payloads use the same rules. Legacy mailbox helper copies/twins
  are disabled in default mode.
- **Singleton state:** owning initializers are elaborated; reads copy at sinks,
  overwrites deep-drop the replaced value, and teardown deep-drops state.
- **Slabs/pools:** snapshots are independent values. Replacement, release/reset
  and rejected fixed-slab operands release nested storage, not just outer headers.
- **Runtime contracts:** non-self push deep-copies existing nested elements;
  setAt releases replaced elements. Split-lines returns owned line strings and
  consumes its input. Read-file/get-env release transferred names. Argument
  strings are cloned from OS storage. Same-type read arguments certify a fresh
  result ahead of another argument's containment-based view classification.

## Test-first evidence

New failing tests preceded fixes for common-before-clone placement, explicit
moves, polymorphic copy/drop, consuming generic parameters, task cleanup,
mailbox payloads, select-state cleanup, runtime imports, split-lines ownership,
slab/pool deep lifecycle, non-self push aliasing and join-result lifetime.

`ownership_glue` includes native D/Odin tests independently of placement,
generated Odin procedures checked with `TUCK_TRACK=true`, and compiler-level
tracked runs. It tests empty storage, nested/triple sequences, arrays, records,
recursive sums, generic substitution, inactive results, repeated reset,
conditional nested slots, task-result replacement and fixed-slab failure.
Owning fill remains intentionally rejected by TK-TY37; this work did not change
the existing scalar-fill language contract.

The final integration regressions cover computed-receiver evaluation once,
earlier operand ordering, unchosen branches, short-circuit evaluation, repeated
loop conditions, and selected value-match arms on all three backends.
Singleton tests cover both handler reads and explicit any-depth projections.
The nested snapshot pin requires an explicit common copy, ordinary all-backend
execution, and tracked Odin execution: the native Odin crash was not exposed
by allocation tracking alone, so tracking is not the sole acceptance criterion.

After integration fixes, the focused gate passed ownership_glue, ownership_rules,
value_semantics (76), memory (8), recursive_types (73), slabs (45), pools (14),
task_select (8) and actor_result (25). The generated example gates passed
odin_backend (113) and d_backend (185). Additional focused gates passed ssa (31),
groups (39), with_update (26), interface_dispatch (26), cli_smoke, diagnostics (44),
mailbox_full (20), interface_seq (26), loop_var_type (17) and end_to_end (22).

The known-bug default probes passed for **A39 and A41-A45**, and their markers
are now `bugFixed`. The targeted known_bugs gate passed 184 assertions; the
independent group-provider bug remained open. The latest known_bugs gate passed
185 assertions, including an added all-backend runtime check for the changed
toStr golden. Recursive-tree tracked expectations
now require exit 0, not the old expected leak exit 90. The two-million-append
budget still passes; the source-oracle cross-check now distinguishes a replaced
old value from the next loop iteration's live replacement.

The toStr golden changed because a borrowed owning temporary is now named on
the common tree. Runtime behavior remains string concatenation. Legacy debug
fixtures explicitly select legacy mode so their diagnostic comparisons remain
meaningful rather than depending on an outdated default.

## Final gate

An earlier full run exposed integration failures in record reconstruction,
singleton-state snapshots, generic exit resets, interface-return temporaries
and dropped-result error routing, plus stale emission goldens and bug counts.
These were corrected with focused regressions; the verifier was not disabled.

One gate attempt was stopped after independent review reproduced a missing copy
on a nested singleton-state snapshot. The new regression failed both emitted-copy
and ordinary Odin execution checks before the any-depth classification fix.
The affected ownership/value/SSA/reconstruction suites then passed.

Final command: `./tests/run --quiet --jobs:8`.

- **56 suites ran; all 55 non-complexity suites passed.**
- **Raw command exit: 1.** The sole failing suite is `complexity`.
- Complexity remains deferred as explicitly requested. Its thresholds were
  not raised or disabled: ceiling 20, heavy-routine limit 11. Actual result:
  2 routines exceed the ceiling; 17 have complexity at least 15.
- Test execution took 538.5 seconds; total gate time was 539.0 seconds.
- All 48 gated examples passed. Example 16 remains explicitly ungated because
  `copyFrom` is undeclared; 48 of 49 sources emit for each backend.
- Eight existing known-bug pins remain open: six cross-module cases, one
  receiver-dependent group-provider case, and one task-timeout/loser case.
  None is relabeled as fixed by this ownership work.

This is functional acceptance of OWN under the owner's complexity deferral,
not an all-green raw full run, universal runtime conformance, or feature parity.

## Boundaries and follow-up

This is not a replacement collector or a new freeing-policy design. D coroutine
GC-root registration, record-passing measurements and explicit layout questions
remain separate roadmap work. No shared C runtime was imposed.

Foreign code is a trusted boundary: an extern must satisfy the stated transfer
and result contract. Arbitrary native reference classes, pointers and native
unions do not become Tuck-owned values by inference. New or currently unsupported
type representations require explicit glue and end-to-end acceptance tests.
Anonymous/parameterized payload sums and imported composition retain their
existing checker/backend limits; this checkpoint does not claim universal
language-feature parity.

Next roadmap item is DGC (collection inside a task): reproduce and pin it before
choosing supported root registration or scheduling changes. The owner must choose
the scope of that item before implementation; no unrelated item started here.
