# sys.dynload — Nim API

## Purpose
Open a shared library at runtime and pull a function out of it by name — the `dlopen`/`dlsym` half of talking to code that wasn't there when you compiled. `sys.ffi` supplies the type that says how to call it.

## Protocols implemented
`Library` is `Resource` (`open`/`close`/`isOpen`) and `Gettable[string, T]` — looking up a symbol by name genuinely is `get(target, key)`, and that single observation gives this module almost its whole API for free.

## The API

```nim
type Library* = object   ## Resource + Gettable. Closes itself when it leaves scope

proc open*(path: Path; resolveNow = false): Library
  ## Raises `IoFailure(problem: Missing)` with the loader's own message attached — "undefined
  ## symbol: foo" is the only useful thing to say, so it is not thrown away.
  ## `resolveNow = true` is RTLD_NOW: pay for every symbol up front and fail here, rather
  ## than at the first call from somewhere unrelated.
proc tryOpen*(path: Path; resolveNow = false): Option[Library]
proc openSelf*(): Library          ## symbols already in this process
proc close*(lib: var Library)      ## idempotent; `=destroy` calls it too
proc isOpen*(lib: Library): bool

proc get*[T](lib: Library; name: string): Option[T]
  ## Absent if the symbol isn't there. **`T` is your assertion, not a check** — no library
  ## format on any platform records a callable signature for a loader to verify against,
  ## so getting `T` wrong is a crash, not an exception. Declare `T` with `sys.ffi` and only
  ## from the library's own header.
proc has*(lib: Library; name: string): bool
  ## Feature-detect an optional entry point without going anywhere near the error path.

proc libraryFile*(base: string): Path
  ## "jpeg" -> libjpeg.so / libjpeg.dylib / jpeg.dll. The whole of platform naming, once.
proc librarySuffix*(): string
```

**When you need this, and when you don't.** Nim already binds libraries at load time with a pragma: `proc jpegVersion(): cint {.importc: "jpeg_version", dynlib: "libjpeg.so.62".}` needs nothing from this module and is the right answer for a library your program cannot run without. `sys.dynload` is for the cases where the decision is genuinely made at runtime — a plugin discovered by scanning a directory, an accelerated codec used only if it happens to be installed, a version probe that must not abort startup. Reaching for `Library.open` when a `{.dynlib.}` pragma would do is the common mistake, so it is named here rather than left to be discovered.

**Nim notes.** A resolved symbol is a plain `proc` value with an explicit calling convention — `type Decode = proc (input: ptr byte; n: csize_t): cint {.cdecl.}` — so calling it is ordinary Nim with no trampoline. `Library` is an object with a `=destroy` hook, which means Nim's ARC/ORC unloads it at end of scope; a `proc` value fetched from it is *not* tracked, so keep the `Library` alive at least as long as anything you called out of it. That is the one lifetime rule this module cannot enforce, and it says so.

## Friendly-naming notes

| Rust/POSIX name | Nim name | Why |
|---|---|---|
| `dlopen` / `Library::new` | `open(path)` | `Resource`'s verb, so `retry(lib, 3, 100.ms)` works on it with no new code |
| `dlsym` / `unsafe symbol::<T>()` | `get[T](lib, name)` | it is a lookup by key that can legitimately miss. `Option`, exactly as the table says |
| *(open question)* `has_symbol` | `has(lib, name)` | resolved for free: `Gettable` requires `has`, so feature detection came with the protocol |
| `Symbol<'lib, T>` wrapper | a bare `proc` value | Nim has no lifetime to hang on it, so the wrapper would have been pure ceremony with no guarantee behind it |
| `Library::open_self` | `openSelf()` | unchanged; already the clearest name |
| `library_filename("jpeg")` | `libraryFile("jpeg")` | shorter, and returns a `Path` rather than a string to re-parse |
| `RTLD_LAZY` / `RTLD_NOW` | `resolveNow = false` | resolved: one trailing named argument instead of a flags integer nobody remembers |
| `unsafe fn` | a doc comment that says so | Nim has no `unsafe` keyword. The honesty has to be in the documentation, and it is |

## In use

```nim
# image-thumbnailer: a system library the program genuinely depends on
var jpeg = open(libraryFile("jpeg"), resolveNow = true)
type CreateDecompress = proc (info: ptr JpegInfo): void {.cdecl.}
let createDecompress = jpeg.get[:CreateDecompress]("jpeg_CreateDecompress")
                           .orRaise("libjpeg is installed but too old — no jpeg_CreateDecompress")

# mp3-player: an optional accelerated codec, and a graceful shrug if it isn't there
let plugin = tryOpen(codecDir / libraryFile("mp3fast"))
let decodeFrame =
  if plugin.isSome and plugin.get().has("decode_frame"):
    plugin.get().get[:DecodeFn]("decode_frame").get()
  else:
    builtinDecodeFrame            # same signature; the rest of the player never finds out
```

## Vocabulary exceptions
None. This module turned out to be `Resource` plus `Gettable` and nothing else — every operation it has is one of the structural verbs at its ordinary signature. That is worth recording as the vocabulary's cleanest fit in the tier: a module that looked like it needed a bespoke `Symbol` type and an `unsafe` marker needed neither, once symbol lookup was recognised as a keyed `get` that can miss.
