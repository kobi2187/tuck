# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Tuck is a systems language that transpiles to **Nim** and **Odin**. The compiler
itself is written in Nim. Two backends, one checked AST.

## Read first

`LANGUAGE-OVERVIEW.md` §0 "What will surprise you" — several Tuck constructs
behave differently from what a C/Go/Rust/Nim/Python reader expects. Skipping it
produces the common failure: reading a working feature as a bug.

Documents are ranked by trust in `README.md`. The order that matters:
**the compiler beats `LANGUAGE-OVERVIEW.md` beats `tuck-spec.md` beats
everything else.** `tuck-spec.md` describes intent and can be ahead of the code.
If a document and the compiler disagree, the document is the bug.

`COMPILER-TOUR.md` is the architecture reference — the 8-stage pipeline, the
module dependency graph, and *why* each stage exists. Do not duplicate it here;
read it.

## Build and test

```sh
nim c --hints:off -o:tuck tuck.nim   # build the compiler
./quick-test.sh                      # INNER LOOP: check-only, ~2s
./tests/run                          # every suite, every assertion (~30s)
./tests/run loop_var_type typecheck  # named suites (repeatable)
./tests/run --quick                  # + `tuck c`: emits/omits/goldens (~5s)
./tests/run --bless                  # rewrite goldens
./tests/run --jobs:N                 # override the parallel pool bound
TUCK_REQUIRE_ODIN=1 ./tests/run      # fail rather than SKIP if Odin is absent
```

`run-all-tests.sh` is a thin wrapper over `tests/run`; both are the pre-commit
gate. `tests/run` is a **script** that conditionally rebuilds `tests/.runner-bin`
from `tests/runner.nim`, `tests/harness.nim` and `tests/suites/*.nim`, then
rebuilds `tuck` at stage 1 — so the suite always runs the current tree. Never
invoke `tests/.runner-bin` directly: a stale binary once made an unverified fix
report green.

Modes filter by **verb**, not by file — every suite runs in every mode, and
assertions needing a deeper verb report SKIP. `--check` runs `tuck ch` only;
`--quick` adds `tuck c`; the default adds `nim`/`odin` build-and-run. Builds
dominate the clock (`tuck build` ~1.05s vs `tuck ch` ~5ms), which is the whole
reason the modes exist.

## Running the compiler

```sh
./tuck l  file.tuck        # lex     — dump tokens
./tuck p  file.tuck        # parse   — dump the tree (--ast for JSON)
./tuck ch file.tuck        # check   — types + effects, no output
./tuck c  file.tuck        # compile — emit .nim (--odin for .odin)
./tuck b  file.tuck        # build   — emit and link a binary
./tuck explain TK-TY15     # what a diagnostic means, and how to fix it
```

When a construct behaves oddly, `./tuck p --ast` **first**. Gradual typing means
sketch code and a destroyed parse tree both read as `Unknown` — the dump tells
them apart.

## Reading the compiler

**Do not read whole Nim files.** `nimoutline <file.nim>` (in `/usr/bin`) emits a
table of contents — every type and routine with its full signature and line
number — at roughly 1/11th the size. `compiler/typecheck.nim` is 3611 lines and
313 lines of outline. Read the outline, then `Read` the specific line ranges it
points at.

The outline also exposes things grep hides: the export surface (only ~12 of
~180 procs in `typecheck.nim` are `*`), and the naming taxonomy the file is
built on — `synth*` returns a type, `as*` returns nil for "not mine" (the
ordered-interpretation pattern), `check*` asserts, `fail*` raises, `collect*`
builds tables.

`tools/cyc` (was `tools/cc`) measures cyclomatic complexity on the real Nim AST:
`./tools/cyc lexer.nim tuck.nim compiler/*.nim` prints worst-first, and takes
`--gate/--budget/--debt/--heavy` to run as the ratchet.

## Invariants a change must not break

**Emitted output under `examples/` is tracked on purpose.** The `.nim` and
`.odin` beside each `.tuck` are the compiler's real product. After any codegen
change run `tools/emit_examples.sh`, then read `git diff examples/` — that diff
*is* the review. An unexpected diff there is the signal. A codegen commit
without re-emitted output is incomplete. (`.bf` Beef output stays ignored.)

**Ratchets only move one way.** `tests/suites/complexity.nim` holds CEILING
(no proc may exceed), DEBT (sum of `cc - 5` over every proc above 5) and HEAVY
(procs at `cc >= 15`), measured on the real Nim AST by `tools/cc.nim`. They are
set to whatever the tree currently is and are **lowered by hand, never raised**.
The gate prints "tighten --debt/--heavy to N" when it has slack.
`MISSING-FEATURES.md`'s open-bug count is likewise checked against the suite by
`tests/suites/end_to_end.nim`.

**Fixing a bug is a two-line change.** `tests/suites/known_bugs.nim` states the
*correct* behaviour as a real assertion plus a marker: `bugOpen` expects it to
fail and reports it; `bugFixed` makes it a permanent regression guard. When a
`bugOpen` assertion starts passing the suite fails and tells you to flip the
marker. Nothing is ever deleted.

**Diagnostic numbers are permanent.** `compiler/diagnostics.nim` is the registry
(`TK-` + two-letter category + number). A deleted diagnostic *retires* its
number; it is never reused. Add new ones at the end of their category block, so
`tuck explain TK-TY41` never lands a user on an unrelated rule.

**`case` over an enum should take no `else`.** A big flat dispatch is left whole
so a new AST node kind produces a compile error in every backend that has not
handled it; `else: discard` trades that guarantee for a silent gap. Length is not
the enemy; nesting is — arms delegate to small named procs, the dispatch stays
flat. Note this is the *rule*, not yet the tree: both codegen decl dispatches
currently end in `else` (`codegen.nim:1848`, `codegen_odin.nim:2315`), and
`ast_serializer.nim` no longer hand-writes a `case` at all — it delegates to
`jsony`. `COMPILER-TOUR.md` still describes the superseded serializer design.

**Each construct gets its own AST node kind.** `on select` got real `exkSelect` /
`dkSelect` nodes rather than being smuggled in as a `match` with a fake subject.
The clever reuse always costs more later, because every downstream stage has to
learn the trick.

**Both backends lower their own deep copy** of the checked AST (`config.nims`
enables `--deepcopy:on` for this). Lowering mutates in place; sharing one tree
means the second backend lowers already-lowered code.

**Pass ordering is load-bearing and invisible.** Typechecking resets the shared
semantic side-table, so `semantics.nim` must run *after* it or its notes are
wiped before codegen. Constraints like this are written on `checkOrDie` in
`tuck.nim` — when you find a new one, write it down there.

## Two kinds of example

`examples/` holds two artifacts, told apart by whether the file has `fn main`:

- **No `fn main` — a syntax specimen.** Claims only "this is how the construct
  is written". Compiling is the whole assertion; many describe features whose
  *meaning* the compiler cannot execute yet.
- **`fn main` — a program.** Claims "this runs"; with `-> int`, "and computes
  this". Run-gated with an expected exit code (`tests/suites/odin_backend.nim`,
  `cli_smoke`).

A compile-only example is not weakly tested — it is a specimen correctly tested.

## Writing tests

Suites are `tests/suites/*.nim`, registered in `suites/all.nim`; assertions come
from `tests/harness.nim`. Snippets go in via `t.src` (or `srcNamed` / `addFile`
for multi-module cases), then: `okCheck` / `badCheck` (typecheck), `emits` /
`omits` / `emitsOdin` / `omitsOdin` (generated text), `runs` / `outputs` (exit
code and stdout), `frozen` (golden). `t.quietly:` runs an assertion for its
outcome only, to be read by `bugFixed` / `bugOpen`.

A failed emit is reported *as* a failed emit, never as "pattern absent" — that
distinction exists because a bug entry whose own `.tuck` stopped compiling read
as open long after the compiler was fixed.

## Layout

```
lexer.nim          text -> tokens
tuck.nim           the CLI driver; checkProgram is the whole pipeline
compiler/          parser -> rewrite -> typecheck -> semantics -> lowering -> codegen
  optimize.nim     OPTIONAL passes, off unless -O names them
  tuckrt/          the Odin runtime (the Nim one is compiler/tuck_*.nim)
std/               the standard library, in Tuck
tests/suites/      one .nim per suite; harness.nim holds the assertions
tools/             cc.nim (complexity), emit_examples.sh
benches/           measurements, with SCORES.md as the ledger
```
