# sys.ffi — Nim API

## Purpose
Call C, and let C call back. Declare a foreign function, match a C struct's layout exactly, hand a buffer across the boundary and get one back — with the ugly parts named honestly rather than hidden.

## Protocols implemented
**None — domain module.** Crossing into foreign code is not a structural operation on a value; there is nothing here to `get`, `list` or `open`. The one shape it does borrow is `View[byte]`, so buffers cross the boundary in the same type the rest of the library already uses.

## The API

Most of this module is Nim's own language, which is the finding: where Rust needs `extern "C"` blocks plus a `bindgen` tool plus `#[repr(C)]`, Nim has pragmas.

```nim
# 1. Declaring a foreign function. Calling convention is per-declaration, never ambient,
#    so one binary can talk to a POSIX library and a stdcall DLL without a build flag.
proc jpegReadHeader(info: ptr JpegInfo; requireImage: cint): cint
  {.importc: "jpeg_read_header", header: "<jpeglib.h>", cdecl.}
proc getLastError(): uint32 {.importc: "GetLastError", stdcall, dynlib: "kernel32".}

# 2. Matching a C struct. Nim objects are already C-layout; the pragmas say so out loud.
type JpegInfo* {.importc: "struct jpeg_decompress_struct", header: "<jpeglib.h>",
                 bycopy, incompleteStruct.} = object
  outputWidth* {.importc: "output_width".}: cuint
  outputHeight* {.importc: "output_height".}: cuint
type Rgb* {.packed.} = object          ## when *you* define the layout C must agree with
  r*, g*, b*: uint8

# 3. Header ingestion, the Zig-@cImport idea, at build time and with no generated file:
cImport("mad.h", includes = ["/usr/include", "vendor/libmad"], defines = {"MAD_FIXED": "1"})
  ## Runs the platform C preprocessor and emits declarations into this module's namespace.
  ## Falls back loudly: a macro it cannot reduce to a constant is reported by name and
  ## skipped, never silently guessed at. Hand-written `{.importc.}` always still works.

# 4. Crossing with buffers and text — the part that actually needs library code:
proc toC*(v: View[byte]): (ptr UncheckedArray[byte], csize_t)
  ## Pointer and length from a borrowed view. No copy; valid while `v` is.
proc fromC*(p: ptr UncheckedArray[byte]; n: csize_t): View[byte]
  ## Borrows C's memory. You are promising it outlives the view; this is the one
  ## promise the compiler cannot check for you.
proc asCString*(t: Text): cstring       ## NUL-terminates in place. `Text` keeps room for it
proc toText*(p: cstring; memory = defaultMemory()): Text   ## copies; raises on invalid UTF-8
template withOwned*(p: pointer; free: proc (p: pointer) {.cdecl.}; body: untyped)
  ## Scoped ownership of a pointer C allocated: runs `body`, then calls `free` — even if
  ## `body` raises. The `defer` everyone forgets, written once.
```

**Nim notes, and one is a real constraint.** A callback handed *to* C must be `{.cdecl, gcsafe.}` and **cannot be a closure** — no captured variables, because there is no environment pointer in a C function pointer. Every C library that takes callbacks also takes a `void* user_data`; pass your state through that and cast it back inside. `image-thumbnailer`'s row-by-row decode callbacks are exactly this shape, so the constraint shows up on day one rather than as a late surprise. Second: nothing on the C side is visible to Nim's collector, so a Nim `seq`/`Text` handed to C must stay alive on the Nim side for the whole call — hold it in a local, don't pass a temporary. Third: `cint`, `culong`, `csize_t`, `cchar` and friends are already in Nim's `system`, sized correctly per platform, so this module re-exports them rather than defining a parallel set.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `extern "C" { fn f(); }` block | `{.importc, cdecl.}` on the proc | per-declaration, which is what the design wanted; the block was only a way to group them |
| `#[repr(C)]` | `{.bycopy.}` / `{.packed.}` / plain object | Nim objects are C-layout already; the pragma is needed only where you're overriding it |
| `bindgen` (separate tool, checked-in output) | `cImport(...)` | build-time, no generated file to go stale, no second toolchain in the build |
| `c_int`, `c_size_t`, `c_void` | `cint`, `csize_t`, `pointer` | Nim's own, already correct on LP64 and LLP64. A parallel set would be a synonym |
| `CStr::from_ptr` / `to_str` | `toText(p)` / `asCString(t)` | the `to<Format>` verb, matching `toText` in `alloc.string` exactly |
| `slice::from_raw_parts` | `fromC(p, n): View[byte]` | says which side the memory came from, which is the only question that matters |
| `unsafe { }` | `withOwned`, plus doc comments | Nim has no `unsafe` block; scoping the *lifetime* problem is worth more than a keyword |
| *(none)* | `withOwned` | new. Every FFI binding hand-rolls this `defer`; one template retires all of them |

## In use

```nim
# image-thumbnailer: libjpeg's row-callback shape, with state through user_data
type Sink = object
  rows: var Grid[Rgb]
  y: int

proc putRow(info: ptr JpegInfo; data: ptr UncheckedArray[byte]; n: csize_t): cint
    {.cdecl, gcsafe.} =                       # not a closure — nothing captured
  let s = cast[ptr Sink](info.clientData)     # state arrives through libjpeg's own slot
  copyInto(s.rows.row(s.y), fromC(data, n))   # View[byte], no copy on our side
  s.y.inc; 1

# mp3-player: one decoded frame, buffer out and buffer in, nothing allocated per frame
let (inPtr, inLen) = window.view().toC()
withOwned(madOpen(), madClose):
  discard decodeFrame(inPtr, inLen, samples.toOpenArray()[0].addr, samples.count.csize_t)
```

## Vocabulary exceptions
- **`toC` / `fromC` are `to<Format>` verbs with an unusual "format".** The format is "how C wants to see it" — a bare pointer and a length — and naming the destination is more informative than `toRawParts` would be.
- **`cImport` and `withOwned` are domain macros, not verbs on a value.** Both act on the program rather than on data; the structural table has nothing to say about either, which PROTOCOLS explicitly allows.
- **This module's honesty is documentation, not types.** Rust marks the danger with `unsafe`; Nim has no equivalent, so every proc here that can produce a dangling pointer says which promise the caller is making, in its own doc comment. That is a weaker guarantee, and it is recorded as weaker rather than dressed up.
