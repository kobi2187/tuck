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
| core | array, cmp, convert, error, fmt, geom, hash, iter, num, str (`text`), types | yes | pass | pass | pass |
| platform | power (sleep depths, wake sources), boot (regions, lookup, overlap) | yes | pass | pass | pass |
| sys | env (defaults, PATH split, `$VAR` expansion) | yes | pass | pass | pass |
| std | math (Decimal, statistics, float functions), chrono (pure calendar; no zone database), perf (stopwatch, counter, histogram), testing (results, report), i18n (case folding, edit distance, words, graphemes, Latin-1 normalization), queue (append-only log over std/fs) | yes | pass | pass | pass |
| alloc | deque, list, map, set, string, vec | yes | pass | pass | pass |
| std | encoding (JSON print/access/parser, base64, hex, CSV), compress (CRC-32, Adler-32, inflate of all block kinds, fixed-Huffman LZ77 deflate, zlib, gzip; no Zstd), archive (tar/ustar pack and unpack, 100-byte names), random (PCG32: ranges, floats, shuffle, sample, weighted pick, gaussian), crypto (SHA-256, HMAC-SHA256, constant-time compare), log (formats, levels, `ConsoleSink`), regex (parser, compiler, backtracking VM, find/replace/split/glob), net-http (URLs, percent-encoding, queries, request/response text, headers, cookies), cli (command tree, parser, usage, table, ANSI) | partial | pass | pass | pass |
| platform | dsp (biquad, moving average, RMS), watchdog (actor: configure, start, feed, check, stop), board (libc-shim: `group Board` with ticks and heap region, heap carving, `HostBoard` and its console as a `Sink`), hal (one group per peripheral kind: output/input pin, I2C, SPI, ADC, PWM; pulse, debounce, register read/write with retry, averaging, duty; a simulated device per group) | yes | pass | pass | pass |
| sys | process (`ExitStatus`, `statusOf`, `run` over `runCommand`), path (normalize, join, parent, base name, extension, relative paths), clock (distinct wall-clock Timestamp, saturating `since`, ISO 8601 format/parse with offsets, human durations; no monotonic Instant until the runtime has one), stream (sys.io: `Source`/`Sink` groups, read-all/exact/line and copy generic over them, in-memory providers; module named `stream` because `io` is reserved), socket (sys.net: `TcpStream` as `Source`/`Sink` over std/net, `dial`/`serve`/`acceptOne`), files (file reader and sink providers for those groups, lines in and out, copy, write under new folders, folder entries as paths; no recursive walk until the runtime can tell a folder from a file) | yes | pass | pass | pass |
| core | slice, mem (designs say fold away); ptr, atomic, sync-cell, simd | no | | | |
| alloc | allocator, box, rc, fmt | no | | | |
| sys, std, platform | everything else | no | | | |
| sys (dropped) | sync, thread, ffi, dynload: the language does their job (actors and tasks, `extern`); see INDEX.md | — | | | |

## What dogfooding found (all fixed)

| Finding | Where it was fixed |
|---|---|
| `core.hash` trapped on u64 overflow: FNV multiplies past 2^64 on purpose, and u64 arithmetic traps by default | the module: the multiply is done in a `[wrapping]` type |
| `alloc.deque` did not check: a local stated `Seq[T]` inside a generic fn lost its `T`, so `{items: xs} Ring` said "cannot infer generic parameter 'T'" | the checker (`bodyGenerics`) |
| `core.str.text.split` crashed on Odin when called from another module with a literal: the callee frees its text, and the importer read an imported fn as body-less so never made the argument an owned copy | the ownership pass (`Resolution.fnBodies`) |
| a module imported by file name could not be selected | the flag itself |
| list literals, generic payload literals, float-literal arithmetic and `send` payload literals did not adopt the expected width (#135, #136, #140, #141) | the checker |
| `x = f(x)` wiped the variable; sibling-scope locals shared an ownership fate; a `let` repeated across match arms did not build (#139, #142, #143) | the ownership pass and the emitters |
| a module named `fmt` collided with Odin's `core:fmt` (#149); a local made from a const Seq moved the const (#146); an index literal took the float type around it (#147); `if` with a void call and an assignment (#148) | the Odin emitter, the ownership pass, the checker |

Regression guards for the two compiler fixes are in `tests/suites/known_bugs.nim`.

## Skipped modules
None. Every module that was set aside for a compiler bug has been finished, and the
bugs are fixed (`known_bugs.nim` A48-A80; one is still open, #155). Not started inside the
finished modules: `std.cli` prompts and progress (host-backed), `std.compress` dynamic-Huffman
encoder and Zstd.

## Next, in order

1. **D backend** runs every module's checks too (`tests/suites/stdlib_project.nim`, where `dmd` is installed; CI has D 2.112.0). Keep it green as modules are added.
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
