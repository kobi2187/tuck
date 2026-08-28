---
date: 2026-07-28T10:26:03+03:00
session_name: examples-all-green
researcher: Kobi
git_commit: b807c8ef30c141b9db59a2daab6b5265bf982199
branch: main
repository: tuck_lexer
topic: "FFI: binding Tuck to C libraries (curl first, then a large toolkit)"
tags: [ffi, c-interop, codegen, odin, nim, beef, extern]
status: complete
last_updated: 2026-07-28
last_updated_by: Kobi
type: implementation_strategy
root_span_id:
turn_span_id:
---

# Handoff: FFI — binding Tuck to C libraries

## Task(s)

**PLANNED / NOT STARTED.** This handoff scopes the next session's work; no FFI
code has been written. Everything below is investigation of the *existing*
machinery plus one verification spike.

The agreed shape, from discussion at the end of the previous session:

1. **Small library first — curl or wget.** Prove the end-to-end path: a Tuck
   `extern` declaration → emitted binding → linked binary → real call.
2. **Then a large one — Dear ImGui or similar portable C GUI toolkit.** The
   real test: a big API surface, structs passed by value, callbacks, enums.
3. Both must work on **all three backends** (Nim, Odin, Beef) or the gaps must
   be recorded deliberately.

Context for why this matters: Odin was adopted as a third backend during the
previous session and now compiles 28/31 examples. FFI is the single largest
*unexercised* area, and it is the thing that would most validate or undermine
the Odin choice — `foreign import` against a large C API either shines or does
not. See `benches/SCORES.md` and recent commits for the backend's state.

## Critical References

- `compiler/ast.nim:333-336` — the `isExtern` / `externHeader` / `externEmit`
  fields that FFI already hangs off. Read this first.
- `compiler/parser.nim:740-763` — `parseExternDecl`, which parses
  `extern [c, header: "x.h"]:` today.
- `compiler/codegen.nim:1553-1561` — the Nim backend's C-binding emitter, the
  only one that is correct. Use it as the reference for the other two.

## Recent changes

No FFI code changed. One artifact was added:

- `scratchpad/ffi-spike/zlib_spike.odin` — a standalone, **verified working**
  Odin binding to system zlib. Run with
  `odin run scratchpad/ffi-spike -out:/tmp/zs`. Prints the zlib version, a
  real CRC32 over a byte slice, and a `compressBound` result. This is the
  target shape the Odin backend should emit.

Everything else in this session was the coroutine-runtime work committed as
`b807c8e`, unrelated to FFI.

## Learnings

**The FFI machinery is ~40% built already.** This was the main surprise — do
not start from scratch.

- `extern [c, header: "uart.h"]:` **already parses** (`compiler/parser.nim:740`)
  and sets `isExtern` + `externHeader` on every member of the block.
- All three backends **already have an arm** for `m.isExtern and
  m.externHeader != ""`. Only Nim's is correct.

**Per-backend state, verified by reading each emitter:**

| Backend | Site | State |
|---|---|---|
| Nim | `compiler/codegen.nim:1553` | **Correct.** Emits `proc X*(...) {.importc: "cname", header: "h.h".}` |
| Odin | `compiler/codegen_odin.nim:1824` | **BROKEN — emits Beef syntax.** `[CLink] public static extern ...` is not valid Odin. Never ported; no example exercises it, so it was never caught. |
| Beef | `compiler/codegen_beef.nim:1617` | Emits Beef `[CLink]`; plausible but never compile-verified (no BeefBuild here). |

**Two real gaps beyond the broken emitter:**

1. **`externEmit` is dead.** `ast.nim:336` documents `[emit: "nimProc"]` as the
   way to name the exact C symbol, and `codegen.nim:1559` reads it — but
   `parseExternDecl` never parses an `emit` key (only `header`). The only
   `"emit"` match in the parser is `compiler/parser.nim:200`, which is an
   *effect* name, unrelated. So `externEmit` is always `""` and the Tuck name
   is always used as the C name. Fine for `crc32`, broken the moment a C
   symbol is not a legal Tuck identifier.
2. **No link-flag mechanism at all.** Nothing in `tuck.nim` emits `--passL:"-lcurl"`
   or Odin's `foreign import`. A binding will compile and then fail to link.
   This is the piece most likely to eat time.

**Odin's `foreign import` is confirmed working** (the zlib spike). The shape is:

```odin
foreign import z "system:z"
@(default_calling_convention="c")
foreign z { zlibVersion :: proc() -> cstring --- }
```

Note `foreign import` names the *library*, so the Odin emitter needs a library
name, not just a header — a piece of information the Tuck syntax does not
currently carry. That is a language-surface decision, not just codegen.

**Environment gotcha:** `libcurl.so.4` is installed but the `-dev` package is
not, so there is no `libcurl.so` symlink and `-lcurl` fails to link. zlib IS
complete (`/usr/lib/x86_64-linux-gnu/libz.so` + `/usr/include/zlib.h`), which
is why the spike used it. **Either `apt install libcurl4-openssl-dev` first, or
start with zlib** — zlib is arguably the better first target anyway: tiny API,
no network, deterministic output that is easy to assert on.

**Name mangling interacts with this.** `compiler/mangle.nim` prefixes user
names with `tuck_`, and `isManglable` (line 48) deliberately returns false for
`dkFn` when `isExtern` — externs keep their name because the name IS the
foreign symbol. Any FFI attribute work must preserve that predicate. The
docstring in `mangle.nim` already calls this "the existing FFI escape hatch;
an explicit `[extern: "c_name"]` attribute would extend the same predicate
here rather than in three backends" — that is the intended design.

## Post-Mortem (Required for Artifact Index)

### What Worked

- **Reading the AST fields before planning.** Grepping `isExtern|externHeader|
  externEmit` in `ast.nim` immediately revealed that FFI is partly built,
  which changed the task from "design FFI" to "finish and fix FFI". Would have
  wasted a lot of effort designing something that exists.
- **Spiking the target shape in the target language directly**, outside the
  compiler. The zlib spike took minutes and turned "Odin FFI probably works"
  into a verified fact with a concrete code shape to emit. Worth doing before
  any codegen work.
- **Checking all three backends for the same arm.** Found the Odin emitter
  still contains Beef syntax — a bug that no test catches because no example
  uses C bindings.

### What Failed

- Tried: linking against curl → Failed because: only `libcurl.so.4` is
  installed, no `-dev` package, so `-lcurl` cannot resolve. Fixed by: using
  zlib for the spike, which is fully installed.
- Assumption that `externEmit` worked because both the AST field and the Nim
  codegen read it → Failed: the parser never populates it. **Check the parser,
  not just the AST and the emitter**, when judging whether a feature exists.

### Key Decisions

- Decision: start FFI with **zlib rather than curl**.
  - Alternatives considered: curl (original plan), wget.
  - Reason: curl's dev package is not installed here, and zlib is a smaller,
    deterministic, network-free API whose output is trivial to assert on. curl
    remains a good second step once the path works.
- Decision: treat the **library name** as a missing piece of Tuck surface
  syntax, not just a codegen detail.
  - Alternatives considered: infer it from the header name; hardcode per
    backend.
  - Reason: Odin's `foreign import` requires a library, Nim needs `--passL`,
    and neither can be derived reliably from `header: "zlib.h"`. Guessing
    would break on the first library where they differ (e.g. `curl/curl.h` →
    `-lcurl`).

## Artifacts

- `scratchpad/ffi-spike/zlib_spike.odin` — verified working Odin↔C binding;
  the shape the Odin backend should emit.
- `compiler/ast.nim:333-336` — extern AST fields.
- `compiler/parser.nim:740-763` — `parseExternDecl`; where an `emit:` /
  `lib:` key would be added.
- `compiler/codegen.nim:1553-1561` — correct Nim reference emitter.
- `compiler/codegen_odin.nim:1824-1831` — **broken**, emits Beef syntax.
- `compiler/codegen_beef.nim:1617` — unverified.
- `compiler/mangle.nim:48` — `isManglable`, the extern escape hatch that FFI
  attributes must preserve.

## Action Items & Next Steps

1. **Decide the surface syntax for the library name.** Probably
   `extern [c, header: "zlib.h", lib: "z"]:`. This unblocks everything else
   and is a 10-line parser change at `compiler/parser.nim:740-758`.
2. **Wire `emit:` in the parser** so `externEmit` stops being dead. Same
   function, same shape as `header`.
3. **Fix the Odin emitter** (`codegen_odin.nim:1824`) to emit
   `foreign import` + a `foreign` block instead of Beef's `[CLink]`. Use
   `scratchpad/ffi-spike/zlib_spike.odin` as the target.
4. **Add link flags to `tuck.nim`**: `--passL:"-l<lib>"` for Nim; for Odin the
   `foreign import "system:<lib>"` line covers it.
5. **Write `examples/33-ffi-zlib.tuck`** calling `zlibVersion` and `crc32`,
   and gate it in `tests/odin_backend.nim` on RUNNING with a known exit code —
   not merely compiling. (This session proved twice that compile-clean can be
   silently broken.)
6. **Then curl** (`apt install libcurl4-openssl-dev` first), then the large
   toolkit. For ImGui expect the hard parts to be structs-by-value, callbacks,
   and enum constants — none of which the zlib path exercises.

## Other Notes

- **Do not trust compile-only checks for FFI.** The single most repeated
  lesson of the previous session: `26-actor-run` compiled cleanly for hours
  while hanging forever, and a `hasMain` bug made every program silently build
  as a library with no binary. Both were caught only by running binaries and
  checking exit codes. FFI is exactly the area where a wrong binding compiles
  and then segfaults or returns garbage.
- Odin lives at `/home/kl/apps/Odin/odin`, on the interactive PATH only —
  non-interactive shells need `export PATH="/home/kl/apps/Odin:$PATH"`.
- The Odin runtime already vendors C successfully
  (`compiler/vendor/minicoro/minicoro.h`, built into
  `compiler/tuckrt/minicoro.a`), so there is working precedent in-tree for
  compiling and linking C alongside emitted Odin — see how
  `compiler/tuckrt/tuck_coro.odin` does its `foreign import mco "minicoro.a"`.
  That is the *static archive* form; zlib uses the `system:` form. Both work.
- Beef is frozen by an earlier decision — kept as reference, not maintained.
  It is reasonable to leave its FFI arm unverified and say so, rather than
  spending time on a backend slated for removal.
