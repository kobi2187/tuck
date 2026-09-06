# Project Map: Tuck Rosetta-style example corpus

## Goal
**Determine the set of fns and modules Tuck's stdlib should contain.**

~100 small everyday programs, written in the most NATURAL Tuck possible, are
the INSTRUMENT for discovering that. Authors invent fn names freely wherever
the natural phrasing needs one; the accumulated inventions, ranked by how often
they were reached for, ARE the stdlib design. Parser/pipeline bugs found along
the way are a valuable by-product, recorded but not fixed here.

## Component tree
- [x] Syntax ground truth              (status: done — rosetta/SYNTAX.md, from source)
- [x] Core-language spike              (status: done — see DISCOVERIES.md)
- [ ] Batch A: numeric & math          (status: assigned — 20 examples)
- [ ] Batch B: control flow & logic    (status: assigned — 20 examples)
- [ ] Batch C: structs & sum types     (status: assigned — 20 examples)
- [ ] Batch D: collections & arrays    (status: assigned — 20 examples)
- [ ] Batch E: text & everyday I/O     (status: assigned — 20 examples)
- [x] Batch F: .NET-shaped common work (status: done — 20 examples + STDLIB-DESIGN.md)
- [x] Parity: Python                   (status: done — PARITY-PYTHON.md + 15 examples)
- [x] Parity: Rust                     (status: done — PARITY-RUST.md + 15 examples;
                                        owns the opt/result surface)
- [x] Parity: Elixir/Ruby              (status: done — PARITY-ELIXIR-RUBY.md + 15
                                        examples. Agent hit its session limit before
                                        reporting; deliverables verified present and
                                        its 3 failing examples fixed by hand.)
- [x] Stdlib API synthesis             (status: done — STDLIB-PROPOSAL.md is the
                                        cross-batch merge + decision list;
                                        STDLIB-DESIGN.md is batch F's fuller layout)
- [x] Triage pass                      (status: done — 181 examples, 176 check-clean.
                                        The 5 failures are deliberate evidence of
                                        known bugs: elif x2, match-on-bool, expr?,
                                        distinct-unit conversion)
- [x] Language-findings report         (status: done — DISCOVERIES.md, 20 numbered
                                        findings, each with a minimal repro)

## NOT DONE — open for a future pass
- Beef backend parity (Nim backend only throughout).
- Async/actor/concurrency stdlib surface (deliberately out of scope; the core
  language was the target).
- Re-verification of `abs`/`min`/`max`/`clamp` examples after name mangling
  lands — their GREEN status is currently untrustworthy (bug #11).
- Most examples were verified with `tuck check` only; `tuck build` coverage is
  partial because the pending-stub arity bug (#7) blocks multi-field stubs.
  "Wanted it" is better evidenced than "verified it runs."

## Explicitly out of scope (v1)
- Actors, tasks, `on select`, async — separately covered, not core language.
- Registers, pools, arenas, registry, extern/C seam — systems features.
- Beef backend parity — Nim backend only.
- FIXING any bug found. This effort REPORTS; fixes are a later decision.

## Definition of 100%
~100 `.tuck` files exist under `rosetta/examples/`, each a recognizable
everyday task written idiomatically. Every file has been run through
`tuck check` and (where it should run) `tuck build` + executed, with its
actual status recorded. A findings report ranks what the corpus proved:
which parser constructs break, and which invented fns recur most often
(= the stdlib priority list).

## Status legend for per-example records
- GREEN — builds and runs, output correct.
- CHECKS — `tuck check` OK but build/run fails (codegen bug — high value).
- PARSE — parser rejects natural code (parser bug — highest value).
- NEEDS — uses invented fns; blocked on stdlib, otherwise well-formed.
