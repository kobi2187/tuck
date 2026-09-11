# SPEC: Tuck stdlib build order

Not a new spec — the real spec is already split across three trusted documents
(per CLAUDE.md's trust order, compiler beats docs):
- `ROADMAP-GRAPH.md` — the dependency graph and build order [settled]
- `stdlib-project/modules/*/*/API.tuck.md` — per-module contract, one file each [settled per module, verify against compiler before trusting — several were stale, see DISCOVERIES]
- the standing `/goal` — follow the graph, implement by priority, pause on bugs needing a decision, stop when done or blocked

This file only records decisions made DURING this build pass that aren't in
those documents yet.

## Goals
- Finish `core` and `alloc` tiers (the ones with no compiler blocker) before
  touching anything gated on the resource registry or F25.
- Every module: `.tuck` implementation + `./tuck ch` OK + `hostBuilds` on all
  three backends + `runs` exit-code check, same bar as the 11 already done.

## Non-goals (this pass)
- Resource registry implementation itself (spec §7.4) — user green-lit the
  DESIGN, not scheduled the WORK. Blocks core.mem/ptr/atomic, alloc.box/rc/allocator.
  Treated as a foundation gate, not a task in this pass.
- Re-cutting the OLD flat `std/*.tuck` generation into `modules/std/*` — out of
  scope until core+alloc are done.
- platform/* — separate milestone (Lens B/C), not started.

## Decisions log
- **2026-09-11**: recursive sum types (arena/index substitution for ref types)
  already shipped (`57a7e77`, `68674e8`) — confirmed by spike, all 3 backends.
  This retires the open question in ROADMAP-GRAPH §3.4 about tree-shaped data
  needing the F4 stream fork; direct recursive fields work today via a
  synthesized `Seq[T]` handle, no annotation needed.
- **2026-09-11**: `core.iter` ships as plain `:fnRef` parameters (no `bake`
  dependency) — construction (`{...} TypeName`) already gives storable,
  nominal, zero-cost adapters; `bake`'s tuple-emission bug is real but
  separate and doesn't block iter. See DISCOVERIES.

## [risky] sections
None yet flagged for frontier review — nothing built this pass has hit an
architecture-level fork. Escalate here if one appears (see Stage 7 in the
orchestration skill).
