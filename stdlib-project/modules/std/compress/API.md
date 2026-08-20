# std.compress

## Purpose
Streaming compression/decompression codecs — gzip, zlib/deflate, and zstd — each wrapping any `sys.io` reader or writer, usable standalone or as the backing codec for `std.archive`.

## Design lineage
Modeled on Go's `compress/*` package family (`compress/gzip`, `compress/flate`, `compress/zlib` each independently importable, each exposing a `Reader`/`Writer` that wraps an `io.Reader`/`io.Writer`) and Rust's `flate2` crate for the same wrap-any-stream shape. The organizing idea taken from both: compression is a stream transform, not a file format — the file-format concerns (headers, checksums) are a thin layer over the same underlying transform.

## Proposed API
```
// One shared shape across all three algorithms.
mod gzip {
    struct Reader<R: sys::io::Reader>;
    impl<R: sys::io::Reader> Reader<R> {
        fn new(r: R) -> core::types::Result<Reader<R>, core::error::Error>;   // validates header/magic eagerly
        fn header(&self) -> &Header;                    // name, mtime, comment, if present
    }
    impl<R: sys::io::Reader> sys::io::Reader for Reader<R> { /* decompressing pull */ }

    struct Writer<W: sys::io::Writer>;
    impl<W: sys::io::Writer> Writer<W> {
        fn new(w: W) -> Writer<W>;
        fn with_level(w: W, level: Level) -> Writer<W>;
        fn finish(self) -> core::types::Result<W, core::error::Error>;   // flush + trailer; must be called
    }
    impl<W: sys::io::Writer> sys::io::Writer for Writer<W> { /* compressing push */ }
    struct Header { name: Option<alloc::string::String>, mtime: Option<sys::time::SystemTime> }
}

mod zlib { /* same Reader<R>/Writer<W> shape, zlib framing (Adler-32, not CRC-32/gzip header) */ }
mod deflate { /* same shape, raw deflate stream, no header/checksum at all — the shared inner codec */ }
mod zstd {
    // same Reader/Writer shape, plus:
    struct Writer<W: sys::io::Writer>;
    impl<W: sys::io::Writer> Writer<W> {
        fn with_level(w: W, level: i32) -> Writer<W>;             // -7..=22, zstd's native range
        fn with_dict(w: W, level: i32, dict: &[u8]) -> Writer<W>; // shared dictionary, for many-small-payloads use
    }
}

enum Level { Store, Fast, Default, Best }   // maps to algorithm-native levels; Store = level 0 passthrough

// One-shot convenience for small in-memory buffers, built on the streaming types above.
fn gzip_compress(data: &[u8], level: Level) -> alloc::vec::Vec<u8>;
fn gzip_decompress(data: &[u8]) -> core::types::Result<alloc::vec::Vec<u8>, core::error::Error>;
// zstd_compress / zstd_decompress mirror this pair
```

## Key design decisions
- **`deflate` (the raw, headerless codec) is exposed as its own module, not just an implementation detail of `gzip`/`zlib`** — this is what lets `std.archive`'s zip support reuse it directly (zip's DEFLATE method needs the raw stream, no gzip header/trailer) rather than `std.archive` embedding a private copy, which is exactly the composability `archive-cli`'s app profile calls out as the thing being tested.
- **Every `Reader`/`Writer` wraps an arbitrary `sys.io::Reader`/`Writer` generically**, never a concrete file handle — so compressing a single log file, a network stream, or an in-memory buffer use the identical API, and `std.archive` can hand a compressor a writer that goes straight into a zip entry's byte range without an intermediate full-buffer copy.
- **`Writer::finish` is a required, explicit call that returns the inner writer** (not an implicit flush-on-drop) — compression writers must flush trailers/checksums deterministically, and a drop-based flush can silently swallow the error a full disk or closed socket would raise; requiring `finish()` forces the caller to observe that `Result`.
- **`Level` is a small portable enum, not raw per-algorithm integers, for the common case**, but `zstd::Writer::with_level` still exposes zstd's native `-7..=22` range directly for callers who need it — the portable enum is a convenience layer over the algorithm-specific knob, not a replacement for it.

## Validated by applications
- **archive-cli**: the direct exercise of the composability claim — `std.archive`'s zip writer takes a `std.compress::deflate::Writer` wrapping the archive's own `sys.io` output stream per entry, and its tar.gz writer wraps the whole tar byte-stream in a single `gzip::Writer`, validating that both "compress each entry separately" (zip) and "compress the whole container once" (tar.gz) are expressible with the same underlying `Writer` type, just composed differently by `std.archive`.
- **web-downloader**: a smaller but real case — HTTP responses with `Content-Encoding: gzip` are transparently decompressed by wrapping the response body reader in `gzip::Reader` before it reaches the file-write path, confirming the reader side works correctly when the *source* is a live network stream (backpressure-sensitive, not a pre-buffered byte slice) rather than a file.
- **log-grep**: the JSON-lines secondary mode reads `.log.gz`-rotated files directly via `gzip::Reader` wrapping a `sys.mmap`-backed or plain file reader, chained straight into line-splitting — validating the streaming reader composes with `core.iter` the same way an uncompressed file would, with no special-cased "decompress then scan" two-pass step.

## Open questions / risks
Whether to add Brotli given its prevalence in HTTP `Content-Encoding` alongside gzip is an open scope question — it was left out of the Part IV module list and this draft keeps that boundary, but `web-downloader`'s HTTP integration is the concrete case that would motivate revisiting it.
