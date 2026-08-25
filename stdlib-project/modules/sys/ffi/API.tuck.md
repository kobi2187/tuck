# sys.ffi — Tuck translation

## This module is a language feature, and Tuck's version is better.

The Nim design already noticed this: *"Most of this module is Nim's own
language, which is the finding: where Rust needs `extern "C"` blocks plus a
`bindgen` tool plus `#[repr(C)]`, Nim has pragmas."*

Tuck goes further — FFI is `extern` blocks in the language, in four
run-gated flavours, with **no library surface at all**:

```tuck
# (a) runtime extern — implemented by tuck_rt; all of std/*
extern:
  fn readFile({path: str}) -> !{content: str} [io, error: FsError]

# (b) bind a backend-language module, no compiler edit
extern [impl: nim "std/strutils", odin "core:strings"]:
  fn startsWith({s: str, prefix: str}) -> bool

# (c) direct C FFI
extern [c, header: "zlib.h", lib: "z"]:
  fn compressBound({sourceLen: u64}) -> u64 [emit: "compressBound"]

# (d) opaque handle
type Counter = {}
```

Structs by value both directions, C enums with explicit values, and
callbacks are all run-gated on both backends.

## What the Nim design contributed that's worth keeping as *rules*, not code

- **The pointer containment rule** — the three-way table in
  `FRICTIONS.md` #7: pointers legal as parameters, `cstring`/`Buf` illegal
  as returns, opaque handles exempt, storing illegal always. This is the
  safety property `sys.ffi` exists to provide, and it's enforced by the
  checker rather than by a library type.
- **`readDevice`/`writeDevice` naming** (the Nim pass's rename of
  `read_volatile`/`write_volatile`): *"volatile" says nothing about why;
  "device" says exactly when*. Belongs to `platform.hal`, but the naming
  argument was made here.
- **C enum values are load-bearing** — `= 10` explicitly, because "a
  mis-numbered tag is silently the wrong constant at the ABI boundary."
  That's documentation for `extern` users, not a function.

## The two real gaps, both already recorded elsewhere
1. **Opaque handles cannot be stored**, so a binding that needs to keep a
   connection between calls needs a safe key plus impl-side state — see
   `std.db`'s writeup, where this decides the module's shape.
2. **Lifetime is manual.** `LANGUAGE-OVERVIEW.md` says it plainly: "C
   allocated it, C frees it, and nothing in Tuck tracks that yet." A
   `counterFree` that never runs is a leak the language won't catch.

## Recommendation
Drop as a library module; keep its content as `extern` documentation. This
is the cleanest "dissolved into the language" case in the whole corpus —
unlike `core.slice` or `sys.thread`, nothing is lost, and the Tuck version
is genuinely more capable than the Nim one it replaces.
