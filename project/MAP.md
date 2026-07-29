# Project Map: Tuck Compiler Refactor

Readability > simplicity > educational value > raw complexity metrics.
Behavior-preserving throughout: no test expectation moves.

## Component tree

- [x] Verification harness            (status: done — T1)
  - [x] run-all-tests.sh — every tests/*.nim + cli_smoke.sh, single gate
  - [x] Odin artifact prep step (see DISCOVERIES D1)
  - [x] baseline captured -> project/baseline.txt
- [ ] Codegen dedup                   (status: unscoped — T2)
  - [ ] compiler/codegen_common.nim (new) — actorSingletonName, errNameFor,
        lookupFnParams, fieldType, isActorType and siblings
  - [ ] codegen.nim uses codegen_common
  - [ ] codegen_odin.nim uses codegen_common
- [ ] Parser dedup                    (status: unscoped — T3)
  - [ ] parseParamList helper (4-5 call sites collapsed)
  - [ ] parseEffectMarkers helper (3 sites collapsed)
- [ ] dkMixin -> dedicated node kinds  (status: unscoped — T4)
  - [ ] dkExtern replaces dkMixin+"extern" string check
  - [ ] dkPending replaces dkMixin+"pending" string check
  - [ ] true mixin/interface keeps dkMixin
- [ ] Typecheck proc splits            (status: unscoped — T5)
  - [ ] synthFieldAccess (~134-300) split into named sub-checks
  - [ ] synthCall (~736-880) split into named sub-checks
  - [ ] const-check closures promoted to top-level procs
- [ ] tuck.nim driver extraction       (status: unscoped — T6)
  - [ ] compiler/driver.nim — check->lower->mangle->emit per backend
  - [ ] build/link concerns out of the CLI verb dispatch
- [ ] Module documentation pass        (status: unscoped — T7)
  - [ ] Header doc on every compiler/*.nim and root *.nim
  - [ ] MODULES.md — purpose, public API surface, integration point

## Explicitly out of scope (v1)
- semLayer / global mutable side-tables — rewrite-scale, not refactor-scale
- Introducing a unittest framework — existing script convention preserved
- Introducing CI — flagged as a gap, not silently added
- Beef backend cleanup (stale --beef refs in cli_smoke.sh) — unrelated
- Fixing the err-match mangling bug (DISCOVERIES D3) — behavior change;
  clean follow-up after T2 lands

## Definition of 100%
A newcomer can open any module, read its header, and know what it does and why
it sits where it does — without holding the whole compiler in their head. The
5 duplication/complexity targets are resolved at the named procs. run-all-tests.sh
output matches project/baseline.txt exactly (one known failure: err-match, D3).
MODULES.md exists and matches the current module set.

## Baseline state (pre-refactor, recorded)
All tests pass EXCEPT cli_smoke.sh's err-match case (D3, pre-existing compiler
bug). Any other failure appearing during T2-T7 is a regression introduced by
the refactor and must be fixed or escalated, never absorbed into the baseline.
