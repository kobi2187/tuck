---
date: 2026-08-11T13:44:46+00:00
session_name: spec-code-audit
researcher: Claude
git_commit: TBD (this session)
branch: claude/spec-code-audit-34xh4q
repository: tuck
topic: "Rulings on the spec-vs-code audit, `when TARGET` implemented, 3 more silent bugs pinned"
tags: [spec, rulings, when, effects, interfaces, actors, alias, known_bugs]
status: complete
last_updated: 2026-08-11
last_updated_by: Claude
type: state_of_the_project
---

# Handoff: the audit's rulings, applied

Follow-up to `2026-08-11_08-43-14_spec-vs-code-audit.md` in this same directory
(read that first for the full evidence trail — this file only records what was
DECIDED and DONE with it). The user ruled on every open question from that
audit in one message; this session applied each ruling.

## Rulings, and what each one meant doing

1. **`pred`/`set` (§3.6) are dropped**, not a gap to fill. Never had a lexer
   keyword or parser rule — formally documented as considered-and-rejected
   rather than left as a stale unbuilt proposal, since purity is already
   covered by effect markers (§3.7) + the `..`-on-`var` rule (§2.3).
2. **Effects (§3.7) require-declared is correct** — the code was right, the
   spec was wrong. Rewrote §3.7 to describe explicit declaration (no
   implicit upward grant), with the "why" (fits the "everything explicit"
   stance in Part 1 better than silent inference). Fixed a stale cross-ref in
   §7.4 that still said "infer-and-propagate."
3. **Concurrency**: minicoro/stackful was a deliberate decision, not a
   drift — confirmed by the git history (`bdd4788`, `c07b028`, `20a9b0c`).
   Rewrote Part 9's opening and §9.1/§9.2/§9.4 to describe the real
   mmap-backed stackful-coroutine runtime, and to say plainly that this makes
   the concurrency layer a Tier 3 (hosted-OS) capability today, not the
   Tier-1/bare-metal thing the old "stackless... 32KB Cortex-M0" text
   claimed.
4. **Interfaces are value objects (copying tagged variant), and that's
   fine** — rewrote §5.3 and Appendix B to describe the copy/tag design
   instead of the abandoned borrowing `{data, vtable}` pair. Verified live
   that the old storability restrictions (no field, no return type) are
   actually GONE in the current checker, not just undocumented — copying
   removed the lifetime hazard those restrictions existed for, so the spec
   text dropping them matches the checker, not just a decision to relax it
   later.
5. **`alias` should mature or be tested** — testing surfaced a second silent
   bug beyond what the original audit found: `alias(...)` never checks its
   RESULT for field-name collisions (two renamed-to targets landing on the
   same name emits Nim with a field written twice, which `nim check`
   rejects). Added a proper spec section (§2.4c — `alias` had never had one
   at all, despite being shipped and tested since example 18) documenting
   the real `expr alias(old: new, ...)` syntax, and pinned the collision gap
   as bug #16 in known_bugs (see below).
6. **`when TARGET` (§8.3) should be implemented** — it was a fully speced,
   0%-built section (the lexer had a dead `tkWhen` token and nothing else).
   Implemented for real this session: `ast.dkWhen`, a parser rule for the one
   supported shape (`when TARGET == "value":`, no elif/else), and
   `modules.resolveWhenBlocks` — run once per loaded module, right after
   load and before anything else touches `m.decls`, and deliberately NOT
   folded into `parseSource`/the AST cache (the cache is keyed on source
   hash, not target, so resolving there would have served a stale target's
   tree on a second run with a different `--target:`). `tuck.nim` gained a
   `--target:NAME` flag. Both backends needed zero codegen changes — by the
   time codegen runs, the module's decls are already exactly the selected
   set. Verified live on both Nim and Odin output. New suite:
   `tests/when_target.sh` (+ mirrored `.nim`), 6 cases.
7. **The silent bugs should be recorded and tested** — added 3 `bug_open`
   pins to `tests/known_bugs.sh` (+ mirrored in `tests/suites/known_bugs.nim`):
   missing-field construction (#14), the `on select` silent-`discard`
   fallback (#15), and the new `alias` collision bug (#16). Updated
   `MISSING-FEATURES.md`'s open-bug table and count (2 → 5) — this doc is
   machine-checked against the suite by `tests/end_to_end.sh`'s "MISSING-FEATURES
   open-bug count matches the suite" case, which would otherwise have started
   failing the moment these landed.
8. **"Get Odin src, compile and test with"** — no `git clone` of
   odin-lang/Odin was reachable (this sandbox's GitHub access is scoped to
   `kobi2187/tuck` only), but a prebuilt nightly binary was reachable from a
   non-GitHub host (`odinbinaries.thisdrunkdane.io` → Backblaze B2), so that
   was used instead: `odin-linux-amd64-nightly+2026-08-10`. Also had to build
   `compiler/tuckrt/minicoro.a` by hand (gitignored build artifact, no
   in-repo build step existed for it — mirrored what `compiler/tuck_coro.nim`
   does: `MCO_USE_VMEM_ALLOCATOR` + `MINICORO_IMPL` over the vendored
   header, `clang -c` + `ar rcs`). With both in place, `TUCK_REQUIRE_ODIN=1
   ./run-all-tests.sh` runs `odin build`/`odin run` for real: 50/50 pass,
   including the ones the previous audit could only source-read. One
   narrower claim (Odin: task WITH ARGUMENTS + a REAL yield point still runs
   inline) could not be isolated — reproducing it hits a different, earlier
   blocker first (`on select` with a real read+timeout is simply not
   lowered for Odin yet, a separate known gap). Recorded as "attempted,
   blocked by a separate issue" in MISSING-FEATURES.md rather than left as
   an unverified claim with no note.

## What was deliberately NOT touched

§11/§12 (compiler architecture — still describes npeg + flat IR + Merkle
cache; reality is recursive-descent + ref-AST + a differently-shaped msgpack
cache) was flagged in the original audit and in ROADMAP.md's own "spec debt"
note, but was not part of the rulings given this session, so it was left
alone. Still open.

## Verification

Full suite green on both backends after every change in this session:
`TUCK_REQUIRE_ODIN=1 ./run-all-tests.sh` → all tests passed, including the
3 newly-added `bug_open` entries reporting OPEN (not erroring — that is the
correct state for a pinned-but-unfixed bug) and the new `when_target` suite.
The cyclomatic-complexity gate (`tools/cc`, budget 280) needed one function
(`resolveWhenBlocks`) split into two to stay under budget — the project's own
dogfooded complexity limit applies to its own Nim source, not just to `.tuck`
programs (a distinction relevant to the still-open question of whether §6.3
should be enforced by `tuck check` itself — unchanged by this session, not a
ruling that was given).
