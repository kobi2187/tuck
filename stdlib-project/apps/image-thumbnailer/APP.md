# App: image-thumbnailer

A CLI batch tool: `thumbify photos/ --width 200 --format jpeg` walks a directory of images (JPEG/PNG/WebP), generates thumbnails, and writes them to an output directory, preserving basic EXIF orientation.

## Why this is a good validation target
This app is included specifically to test the *edges* of the stdlib design rather than its strengths: no module anywhere in the five tiers decodes an image. That is a deliberate omission worth confirming is still the right call, not an oversight — and the app forces a concrete answer for how a stdlib-only program is expected to do image work at all.

## Features
- Walk a directory tree for image files by extension/magic-byte sniffing.
- Decode JPEG/PNG/WebP, resize (box or bilinear filter), re-encode, write output.
- Read EXIF orientation and rotate/flip accordingly before resizing.
- Parallelize across files (this is an embarrassingly-parallel batch job — a good contrast case to `log-grep`'s parallel-scan and `chat-server`'s parallel-connections shapes).
- Skip-if-unchanged (compare source mtime/hash against an existing thumbnail) for fast re-runs.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.process` / `sys.ffi` | **the actual answer**: shell out to (or FFI-bind) an external decoder (a system-provided `libjpeg`/`libwebp`, or a CLI tool) — see validation note |
| sys | `sys.fs` | directory walking, output file writing, mtime comparison for skip-if-unchanged |
| std | `std.async` | bounded-concurrency batch processing across many files |
| std | `std.crypto` | content hashing for the skip-if-unchanged cache key (stronger than mtime alone) |
| std | `std.cli` | progress display across a batch job |
| core | `core.simd` | if a resize filter is implemented in-language rather than delegated, this is where the pixel-math would live |
| core | `core.error` | corrupt/unsupported image files should skip-and-report, not abort the whole batch |

## Validation note: the gap this app confirms, and how it's meant to be filled
No tier in the Part IV design ships an image codec — this app is the concrete check that the omission is correct, following the same reasoning `REPORT.md` already applies to `std.gui`: image codec formats (JPEG's DCT/entropy coding, PNG's DEFLATE + filter prediction, WebP's VP8-derived transforms) are large, patent-and-performance-sensitive subsystems with mature, widely-trusted, actively-maintained C implementations (`libjpeg-turbo`, `libpng`, `libwebp`) that a language stdlib would be reinventing badly if it tried to own them. The design's actual answer for `image-thumbnailer` is that `sys.ffi`/`sys.process` are *supposed* to be the escape hatch here: bind against the system's `libjpeg`/`libwebp` via `sys.ffi`, or shell out to a tool via `sys.process`, and everything else (directory walking, batching, hashing, progress) is genuinely served by the existing stdlib. This is validated, not found wanting — but it does mean `sys.ffi`'s ergonomics matter more than any single app in the first eleven suggested, since this is the category of program (media codecs, compression formats beyond `std.compress`'s scope, hardware-accelerated anything) that leans on it hardest.
