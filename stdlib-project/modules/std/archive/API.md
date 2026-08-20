# std.archive

## Purpose
Read and write zip and tar container formats, streaming, built entirely on `std.compress`'s codecs and `sys.io`'s reader/writer interfaces rather than embedding a private compression implementation.

## Design lineage
Modeled on Go's `archive/zip` + `archive/tar` — two independent, format-specific packages that each accept/produce standard `io.Reader`/`io.Writer` and delegate compression to `compress/flate`/`compress/gzip` rather than bundling their own deflate implementation, which is historically how most languages' zip libraries are built (and a recurring source of divergent, buggy deflate re-implementations across the ecosystem).

## Proposed API
```
mod zip {
    struct Reader<R: sys::io::Reader + sys::io::Seeker>;   // zip needs seek: central directory is at the end
    impl<R: sys::io::Reader + sys::io::Seeker> Reader<R> {
        fn open(r: R) -> core::types::Result<Reader<R>, core::error::Error>;
        fn entries(&self) -> impl core::iter::Iterator<Item = &EntryInfo>;
        fn open_entry(&mut self, name: &str) -> core::types::Result<impl sys::io::Reader + '_, core::error::Error>;
        fn open_entry_encrypted(&mut self, name: &str, password: &[u8])
            -> core::types::Result<impl sys::io::Reader + '_, core::error::Error>;   // AEAD scheme, not legacy ZipCrypto
    }

    struct Writer<W: sys::io::Writer>;
    impl<W: sys::io::Writer> Writer<W> {
        fn new(w: W) -> Writer<W>;
        fn create_entry(&mut self, name: &str, opts: EntryOptions) -> core::types::Result<impl sys::io::Writer + '_, core::error::Error>;
        fn create_entry_encrypted(&mut self, name: &str, opts: EntryOptions, password: &[u8])
            -> core::types::Result<impl sys::io::Writer + '_, core::error::Error>;
        fn finish(self) -> core::types::Result<W, core::error::Error>;   // writes central directory
    }

    struct EntryInfo { name: alloc::string::String, size: u64, compressed_size: u64,
                         mtime: sys::time::SystemTime, mode: sys::fs::Permissions, is_encrypted: bool }
    struct EntryOptions { compression: std::compress::Level, mtime: sys::time::SystemTime, mode: sys::fs::Permissions }
}

mod tar {
    struct Reader<R: sys::io::Reader>;                     // no seek required: tar is a linear stream
    impl<R: sys::io::Reader> Reader<R> {
        fn new(r: R) -> Reader<R>;
        fn next(&mut self) -> core::types::Result<Option<Header>, core::error::Error>;  // advances to next entry
        fn read(&mut self, buf: &mut [u8]) -> core::types::Result<usize, core::error::Error>;  // reads current entry's body
    }
    struct Writer<W: sys::io::Writer>;
    impl<W: sys::io::Writer> Writer<W> {
        fn new(w: W) -> Writer<W>;
        fn write_header(&mut self, h: &Header) -> core::types::Result<(), core::error::Error>;
        fn write(&mut self, buf: &[u8]) -> core::types::Result<usize, core::error::Error>;   // body for current header
        fn finish(self) -> core::types::Result<W, core::error::Error>;
    }
    struct Header { name: alloc::string::String, size: u64, mtime: sys::time::SystemTime,
                      mode: sys::fs::Permissions, kind: EntryKind }
    enum EntryKind { File, Directory, Symlink { target: alloc::string::String } }
}

// Convenience: gzip-wrapped tar, the common ".tar.gz" case — composes tar::{Reader,Writer} with std.compress::gzip.
fn open_tar_gz<R: sys::io::Reader>(r: R) -> core::types::Result<tar::Reader<std::compress::gzip::Reader<R>>, core::error::Error>;
fn create_tar_gz<W: sys::io::Writer>(w: W, level: std::compress::Level) -> tar::Writer<std::compress::gzip::Writer<W>>;

// Integrity check without extraction — used by `archive test`
fn verify(path: &sys::fs::Path) -> core::types::Result<VerifyReport, core::error::Error>;
struct VerifyReport { entries_checked: usize, corrupt_entries: alloc::vec::Vec<alloc::string::String> }
```

## Key design decisions
- **Compression is never re-implemented inside `std.archive`** — `zip::Writer::create_entry` internally wraps the caller's data path in a `std.compress::deflate::Writer`, and `create_tar_gz` is literally `tar::Writer::new(gzip::Writer::new(w))`: the composition is visible in the type, not hidden. This is Design Principle 3 taken as literally as possible, and it's the exact seam `archive-cli`'s app profile identifies as the test.
- **`zip::Reader` requires `Seeker` and `tar::Reader` does not**, reflecting the two formats' genuinely different structure (zip's central directory lives at the end of the file; tar is a pure linear stream of header+body records) — the API doesn't paper over that difference with a fake unified "container" trait that would force tar into pretending to be seekable or zip into pretending to be streaming-only.
- **Password protection uses AEAD (via `std.crypto`) per entry, never legacy ZipCrypto** — `open_entry_encrypted`/`create_entry_encrypted` are separate, clearly-named methods rather than a boolean flag on the plain methods, so a caller cannot silently produce a legacy-encrypted (cryptographically broken) zip entry by mistake; there is no code path that reaches ZipCrypto at all.
- **`verify()` reads and checksums every entry without writing extracted output anywhere** — `archive test`'s requirement — by driving `Reader::open_entry`/`tar::Reader::next`+`read` into a discard sink, reusing the exact same decompression path extraction would use rather than a separate lightweight validator that could drift out of sync with real extraction behavior.

## Validated by applications
- **archive-cli**: the module's entire reason to exist — exercises `zip::Writer`/`Reader` and `tar::Writer`/`Reader` symmetrically for create/extract/list, `create_entry_encrypted`/`open_entry_encrypted` for password protection (validated end-to-end against `std.crypto`'s `kdf`+`aead`), configurable `EntryOptions::compression` levels, and `verify()` for `archive test`; it is also the app that forced `create_tar_gz`/`open_tar_gz` to exist as named convenience wrappers once it became clear "just compose them yourself" was one extra generic parameter of ceremony for the single most common archive format in practice.
- **doc-convert-tester** (indirect, via nothing — noted as a boundary check): does **not** use `std.archive` at all despite converting between structured formats, which is itself a useful negative validation that `std.archive` stayed scoped to container formats and didn't creep into "any structured multi-file bundle" territory.

## Open questions / risks
Whether `zip::Writer` should support writing entries out of a caller-provided order with deferred central-directory patching (useful for very large archives assembled from parallel producers) or whether strict sequential `create_entry` calls are an acceptable limitation is unresolved; `archive-cli`'s "streaming create" requirement is satisfied by sequential writes today, but a hypothetical parallel-archive-builder app would stress this further.
