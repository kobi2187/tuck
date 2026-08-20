# sys.dynload

## Purpose
Loads shared/dynamic libraries at runtime and resolves symbols from them — the `dlopen`/`dlsym` equivalent, letting a program discover and call into code not linked at compile time (plugins, optional codecs, system-provided libraries).

## Design lineage
Modeled on POSIX `dlopen`/`dlsym`/`dlclose` for the core operations, and Rust's `libloading` crate for making the API memory-safe at the boundary that can be made safe (typed, RAII-scoped `Library` handles) while being explicit that symbol resolution itself is fundamentally unsafe (the loaded symbol's actual type is asserted by the caller, not verified by the loader — no dynamic library format encodes Rust/C-level type signatures for the loader to check against).

## Proposed API
```
struct Library { .. }
impl Library {
    fn open(path: &Path) -> Result<Library, DynloadError>;              // dlopen-equivalent
    fn open_self() -> Result<Library, DynloadError>;                    // symbols in the current process, RTLD_DEFAULT-equivalent
    unsafe fn symbol<T>(&self, name: &str) -> Result<Symbol<T>, DynloadError>;  // unsafe: caller asserts T is correct
    fn close(self) -> Result<(), DynloadError>;                         // explicit; Drop also calls this, best-effort
}
struct Symbol<'lib, T> { .. }        // borrows Library; cannot outlive it (enforced by lifetime, not runtime check)
impl<'lib, T> Symbol<'lib, T> {
    fn as_ptr(&self) -> *const ();
}
// Typical usage for a C function pointer symbol:
// type DecodeFn = extern "C" fn(*const u8, usize, *mut u8, usize) -> i32;
// let sym: Symbol<DecodeFn> = unsafe { lib.symbol("mp3_decode_frame")? };
// let f: DecodeFn = *sym;  f(...)

fn library_extension() -> &'static str;      // ".so" / ".dylib" / ".dll" — portable filename construction helper
fn library_filename(base: &str) -> PathBuf;  // "codec" -> "libcodec.so" / "codec.dll" per-platform
```

## Key design decisions
- `symbol::<T>()` is an `unsafe fn`, not a safe one that returns some opaque handle — this is a deliberate, visible admission that no dynamic loader can verify a symbol's true type signature, matching `core.error`'s philosophy of making unchecked contracts explicit rather than pretending a runtime check exists where none can.
- `Symbol<'lib, T>` carries a lifetime tied to its `Library`, so the type system (not a runtime reference count) prevents calling a resolved function pointer after its library has been closed — the one part of this fundamentally-unsafe domain that *can* be made memory-safe at zero cost, so the design does.
- `library_filename`/`library_extension` exist as small, separate helper functions rather than folding platform-specific naming into `Library::open` itself — a caller who already has an exact path (e.g., a plugin discovered by directory scan) shouldn't be forced through name-mangling logic they don't need.
- `close()` is both callable explicitly and invoked by `Drop`, with the explicit path returning a `Result` (some platforms can fail to unload cleanly, e.g. TLS destructors) while `Drop` swallows the error — mirroring `sys.fs::File`'s sync-then-drop pattern so the "explicit control when you need it, safe default otherwise" idiom is consistent across modules.

## Validated by applications
- **mp3-player**: the sole validating app, and it exercises exactly the two use cases this module is designed for — "optionally loading a codec as a plugin" (a discovered `.so`/`.dll` chosen at runtime based on what's installed) and, closely related, `sys.ffi` "calling into a C decoding library." This app confirmed the split between `sys.dynload` (find and open the library, resolve a symbol) and `sys.ffi` (know how to call through that symbol correctly, given a C ABI signature) needs to be a clean two-module handoff: `sys.dynload::Symbol<T>` hands off a typed pointer, and `sys.ffi` supplies the `extern "C" fn` type `T` itself. A naive single merged module conflating "find the library" with "describe the C calling convention" was rejected because a plugin architecture (dynload-heavy, ffi-light: one exported entry-point function) and a "wrap a whole C library" scenario (ffi-heavy: dozens of declared functions, dynload-light: one `Library::open` call) have very different proportions of each concern, and apps besides mp3-player will likely lean toward one side or the other.
- **image-thumbnailer** (Round 2): a stronger validation case than mp3-player alone, and the app's own "Validation note" section is explicit about why: no tier in this design ships an image codec (JPEG/PNG/WebP decoding is exactly the kind of large, patent-and-performance-sensitive subsystem this stdlib deliberately doesn't reinvent), so binding against the system's `libjpeg`/`libwebp` via `sys.dynload` + `sys.ffi` is presented as *the* intended answer, not a workaround. Where mp3-player validates the "optional plugin, one narrow entry point" shape (dynload-heavy, ffi-light — discover an installed codec at runtime, resolve one `decode_frame`-style symbol), image-thumbnailer validates the opposite proportion: a program that unconditionally depends on a real, well-known, multi-function system library for its core functionality (JPEG decode, PNG decode, WebP decode, each with dozens of entry points and struct-heavy calling conventions — quantization tables, color-space info, row-buffer callbacks) rather than one optional function pointer. This confirms `Library::open` needs to work cleanly for "open a specific, expected-to-exist system library by its well-known name" (via `library_filename("jpeg")` → `libjpeg.so`/`jpeg.dll`) just as well as for mp3-player's "maybe this optional plugin exists" case — the same two functions serve both without a second code path, which is what the module claimed but had only one app's evidence for until now.
- Between mp3-player and image-thumbnailer, `sys.dynload` now has two validating apps representing the two ends of its expected usage spectrum (optional single-symbol plugin vs. mandatory multi-symbol system library), which is a meaningfully broader validation footprint than the original single-app case — no other app in the set touches it, which is a smaller residual gap than before but still worth naming.

## Open questions / risks
Whether `sys.dynload` should offer any symbol-existence probing (`has_symbol(name) -> bool`) separate from the fallible `symbol::<T>()` call, useful for plugin systems that want to feature-detect optional entry points without triggering error-path overhead — not in the sketch above, plausible small addition. Lazy vs. eager symbol resolution (`RTLD_LAZY` vs `RTLD_NOW`) is also currently unexposed and may need to be an `open`-time option.
