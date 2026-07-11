---
date: 2026-07-11T10:18:00+03:00
session_name: general
researcher: Kobi
git_commit: 92fcb04
branch: main
repository: tuck_lexer
topic: "Tutorial dogfooding + manager-composition groundwork"
tags: [implementation, tuck, tutorial, mixins, composition, error-model, stdlib]
status: complete
last_updated: 2026-07-11
last_updated_by: Kobi
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: tutorial dogfooding — manager composition works, tutorial files not yet written

## Task(s)
1. **DONE earlier this session**: spec §4.8/4.9 rewritten to error model v2
   (commit 9b77572). Error model v2 itself, stdlib v1 (fs/io/sys/time),
   `tuck build`, extern blocks — all landed in prior commits (a030e14,
   42ffe29, 1402ec1).
2. **IN PROGRESS — the actual deliverable**: larger tutorial programs
   dogfooding the vision (VISION.md). Groundwork commit 92fcb04 done;
   the tutorial `.tuck` files and TUTORIAL.md rewrite are NOT yet written.

## Critical References
- VISION.md — the development process the tutorial must TEACH (top-down +
  pending TDD, manager catalog composed with `+`, declared correctness,
  actors for scale). Written this session from the user's own words.
- ROADMAP.md — feature status matrix + all user rulings.
- progress.md — session-by-session log (bottom = newest).

## Recent changes (commit 92fcb04)
- compiler/modules.nim: `injectImportedTypes` — imported type decls visible
  UNQUALIFIED in importer (user ruling), marked `ImportedTypeMarker`
  (ast.nim const) so codegen skips re-emitting them.
- compiler/codegen.nim: mixin blocks emit plain member fns (fn buckets);
  `isRecordType` + named-field record construction `{f: v} TypeName` →
  `TypeName(f: v)` in BOTH genExpr overloads (was positional = invalid Nim);
  lookupFnParams sees mixin/type member fns (pending excluded).
- compiler/parser.nim: `invariant:` block form (one predicate per line) in
  type AND object bodies; fn-members-in-types REVERTED (see rulings).
- compiler/lowering.nim + typecheck.nim: recurse type/mixin members (mostly
  dormant after revert; harmless).
- tuck.nim / tests/compile_all_examples.nim: call injectImportedTypes after
  load.

## Learnings
- **User rulings this session (recorded in ROADMAP.md + VISION.md):**
  - Types carry DATA only — no fns inside types. Functionality =
    extension-style free fns (C# extensions / Nim first-arg), grouped in
    modules; module-per-manager is the direction, `mixin` keyword fate TBD
    ("need to see more examples").
  - `+` composition merges all fields into a NEW type ("just merging all
    types together"); a manager fn belongs to its manager type by lineage,
    not to any type that happens to share fields (lineage enforcement NOT
    implemented — currently structural subset matching is the de-facto
    mechanism).
  - Imported types come in UNQUALIFIED (fns stay `::`-qualified).
  - Fn name collisions across managers: `::` or a future rename keyword —
    later feature.
  - invariant should be a block (implemented).
- **Verified working end-to-end** (scratchpad probe): cross-module manager
  composition — `import playback` + `type Player = Playback + {title: str}`
  flattens fields, `{...} Player` constructs with named fields,
  `{...} playback::advance` calls the manager fn. Probe files at
  /tmp/claude-1000/.../scratchpad/tut/{playback,player}.tuck (scratchpad is
  session-bound — recreate from this description, it's ~15 lines).
- **Known gap that will bite the tutorial**: passing a record VARIABLE as a
  call payload only works when the fn takes the whole struct or a single
  scalar; codegen explodes STRUCT LITERALS by param order but a var arg is
  passed as one value (`p advance` → `advance(p)` vs
  `advance(position, step)`). This is the old "type-directed lowering"
  backlog item (blocks examples 18/04/12 too). Tutorial must either use
  struct-literal call sites (`{position: pl.position, step: 5} advance`)
  or this gap gets fixed first.
- Session limits hit twice; task list wiped between sessions — progress.md
  and ROADMAP.md are the durable state, tasks tool is not.

## Post-Mortem (Required for Artifact Index)

### What Worked
- Probe-before-writing: tiny scratchpad program exposed the positional-ctor
  bug and confirmed composition works before committing to tutorial text.
- Dogfooding loop: vision statement → probe → compiler fix → commit, each
  fix small and suite-verified (69 checker tests, gate 14/25 stayed green).
- AskUserQuestion rounds to pin design rulings before implementing.

### What Failed
- Tried: fn members inside `type X:` bodies (parser + emission) → user
  rejected: types are data, not classes. Reverted the parser branch.
- Assumed structural dispatch was the intent → user corrected: lineage
  ("pulled in because it works on Playback"), impl-for-now = field merge.

### Key Decisions
- Decision: imported types injected as marked decls per importer.
  - Alternatives: qualified type syntax (`playback::Playback`) in type
    positions; program-wide shared type env.
  - Reason: user ruled unqualified; marker keeps emission single-source
    (Nim import provides the real definition).
- Decision: named-field ctor emission keyed on `isRecordType` lookup.
  - Reason: distinct-type conversions and fn calls keep positional args;
    only record construction needs named fields.

## Artifacts
- VISION.md (new)
- ROADMAP.md (rulings sections)
- progress.md (log through 2026-07-10)
- tuck-spec.md §4.8/§4.9 (rewritten)
- std/{fs,io,sys,time}.tuck, examples/24-stdlib.tuck, examples/14-task.tuck
- compiler/{modules,codegen,parser,lowering,typecheck,ast}.nim, tuck.nim
- thoughts/shared/handoffs/general/2026-07-11_10-18-00_tutorial-dogfooding-managers.md (this)

## Action Items & Next Steps
1. Write the tutorial (task was in progress): staged app under `tutorial/`
   teaching the VISION.md process —
   01 pending skeleton that RUNS → 02 managers-per-module composed with `+`
   → 03 fill pendings with error enums + ok-guards → 04 decision table +
   transitions + invariant block → 05 actors. Each stage must
   `tuck build` + run. Rewrite TUTORIAL.md as the narrative.
2. While writing, dogfood around the record-var call gap (struct-literal
   call sites) or fix type-directed lowering first (bigger, unblocks 18/04/12).
3. Decide `mixin` keyword fate from the tutorial examples (user wants to see
   examples before ruling).
4. Suites to keep green: tests/typecheck_tests.nim (69),
   tests/compile_all_examples.nim (gate 14/25), tests/cli_smoke.sh,
   tests/end_to_end.nim. Wipe `.tuck-cache` dirs after compiler changes
   (build stamp invalidates, but tests create them in examples/ + std/).

## Other Notes
- Commit convention: /commit skill semantics — no Claude attribution, user
  has standing OK to commit freely.
- `tuck build --nim:"--os:standalone --cpu:arm"` = bare-metal path (untested
  on real target).
- config.nims defines nimOldCaseObjects for msgpack4nim AST cache unpacking.
- Sig index (.tuck-cache/index.bin) skips stdlib-dir entries and carries no
  types/error-lists yet — noted ceilings in progress.md.
