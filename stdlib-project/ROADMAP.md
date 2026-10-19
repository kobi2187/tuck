# stdlib-project: dogfooding roadmap

Status 2026-10-19. The designs in this directory (`INDEX.md`, `DIRECTION.md`) name 72
modules; **13 exist as Tuck source** under `modules/`. This file says how they are
used, how they are tested, what building them has already found, and what comes next.

## Using it

```sh
./tuck b prog.tuck --stdlib:stdlib-project            # Nim
./tuck b prog.tuck --odin --stdlib:stdlib-project     # Odin
```

`--stdlib:NAME` (issue #105) takes a directory, or a name found beside the compiler.
Its modules shadow `std/` **by file name**: `import text` finds
`modules/core/str/text.tuck`, `import convert` finds `core/convert/convert.tuck`.
Imports the project does not provide (`seq`, `str`, `fs`, ...) still come from `std/`,
which is where the externs the project stands on live. `when STDLIB == "stdlib-project":`
blocks compile in. Without the flag nothing changes: the blessed `std/` is used.

## Testing policy

* **Every module carries a `main` of its own checks**, exit code 0 = pass, and a
  non-zero code names the check that failed. `tests/suites/stdlib_project.nim` builds
  and runs each one on **Nim and Odin**, so the stdlib is held to the same backends as
  everything else. D is not covered yet (see below).
* **A new function lands with a check in its module's `main`**, in the module's own
  numbering. No separate test file per module: the module and its checks stay together.
* **Cross-module use is tested in the suite** (`usage.tuck`: `split` + `parseInt`),
  because ownership of a call into another module is decided from a signature, and the
  module's own `main` cannot see that.
* **No applications are built here.** `apps/*/APP.md` stay design validation. An app
  would use the manager objects, which sit on these functions; the functions come first.

## State

| Tier | Module | Tuck | Nim | Odin | D |
|---|---|---|---|---|---|
| core | array, cmp, convert, error, fmt, geom, hash, iter, num, str (`text`), types | yes | pass | pass | not run |
| std | math (Decimal, statistics, float functions), chrono (pure calendar; no zone database), perf (stopwatch, counter, histogram), testing (results, report), i18n (case folding, edit distance, words, graphemes, Latin-1 normalization) | yes | pass | pass | not run |
| alloc | deque, list, map, set, string, vec | yes | pass | pass | not run |
| std | encoding (JSON print/access written, Nim passes; parser, base64, CSV not started) | partial | pass | **blocked: #134** | |
| core | slice, mem (designs say fold away); ptr, atomic, sync-cell, simd | no | | | |
| alloc | allocator, box, rc, fmt | no | | | |
| sys, std, platform | everything else | no | | | |

## What dogfooding found (all fixed)

| Finding | Where it was fixed |
|---|---|
| `core.hash` trapped on u64 overflow: FNV multiplies past 2^64 on purpose, and u64 arithmetic traps by default | the module: the multiply is done in a `[wrapping]` type |
| `alloc.deque` did not check: a local stated `Seq[T]` inside a generic fn lost its `T`, so `{items: xs} Ring` said "cannot infer generic parameter 'T'" | the checker (`bodyGenerics`) |
| `core.str.text.split` crashed on Odin when called from another module with a literal: the callee frees its text, and the importer read an imported fn as body-less so never made the argument an owned copy | the ownership pass (`Resolution.fnBodies`) |
| a module imported by file name could not be selected | the flag itself |

Regression guards for the two compiler fixes are in `tests/suites/known_bugs.nim`.

## Skipped, waiting on a compiler fix
A module that hit a compiler bug is left where it stopped, the bug is filed, and the next
module is started. No workaround is written into a module. Finish these after the fixes:

* `std.encoding`: #134 (`_` arm over a payload sum, Odin).
* `platform.dsp`: #135 (float list literals, also noted there) and #140 (arithmetic on float
  literals vs `f32`). Biquad, moving average and RMS are written; the checks that build
  `Seq[f32]` from a list could not be.
* `std.regex`: #139 (`x = f(x)` wiping a Seq in a loop), and #138 on Odin. Parser, compiler to
  a program, backtracking VM, find/replace/split/glob are written.
* `std.log`: #138 (Odin build of a `str` field returned from a payload-sum match), #137
  (effect of an [io] interface call). Formats, levels and `ConsoleSink` are written; Nim passes.
* `std.cli`: #136 (a literal pushed onto `Seq[u8]`). Parser, usage, table and colour are
  written (the interactive prompts and progress are host-backed and not started).
* `std.crypto`: #135 (`Seq[u8]`/`Seq[u64]` list literals). SHA-256, HMAC-SHA256 and a
  constant-time compare are written; the round-constant table cannot be.

## Next, in order

1. **D backend.** Run each module's checks under D wherever `dmd` is installed (the
   harness's `hostRuns` already knows how); CI has D 2.112.0. Expect findings.
2. **Layer-0 gaps** the existing modules already want: `core.fmt` (the string-building
   pieces `alloc.string` stands in for), `core.error`, then `core.slice`/`core.mem`.
   Build order follows `stdlib-layers.md`: lowest layer first.
3. **One satisfier per group, twice.** Issue #105's exit criterion: one program built with
   two stdlib entries emits two different satisfiers for the same group, on all three
   backends. The flag is the mechanism; the second satisfier does not exist yet.
4. **`alloc.map`/`set` are scans.** Both note that a hash-bucket rewrite waits on a
   measurement. `core.hash` now works, so the measurement can be taken.
5. **Where community stdlibs live** (issue #105's open question): `--stdlib:DIR` already
   accepts any directory, which covers a stdlib outside the toolchain. A manifest or a
   search path is a decision for later, once a second stdlib exists.
