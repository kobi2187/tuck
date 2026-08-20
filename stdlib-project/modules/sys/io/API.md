# sys.io

## Purpose
Defines the minimal, composable stream interfaces — `Reader`, `Writer`, `Seeker`, and their buffered wrappers — that every other stream-like thing in the standard library (files, sockets, pipes, compressors, archives, decoders) implements or accepts, so they compose without adapter code.

## Design lineage
Modeled directly on Go's `io.Reader`/`io.Writer` (Principle 3 names this module explicitly as the reference design) and Rust's `std::io::Read`/`Write`. Both converge on the same insight independently: a stream capability should be a single method returning a count and an error, not a fat class with dozens of methods. `sys.io` also borrows Rust's `Seek` (offset-relative seeking with a `SeekFrom` enum) since "can this stream jump around" is a genuinely separate capability from "can this stream produce/consume bytes," and conflating them (as some older APIs do) forces network sockets to fake a broken `seek`.

## Proposed API
```
trait Reader {
    fn read(&mut self, buf: &mut [u8]) -> Result<usize, IoError>;   // 0 = EOF, never blocks-forever silently
}
trait Writer {
    fn write(&mut self, buf: &[u8]) -> Result<usize, IoError>;
    fn flush(&mut self) -> Result<(), IoError>;
}
trait Seeker {
    fn seek(&mut self, pos: SeekFrom) -> Result<u64, IoError>;
}
enum SeekFrom { Start(u64), End(i64), Current(i64) }

// Convenience built on the primitives above, generic over any Reader/Writer:
fn read_full<R: Reader>(r: &mut R, buf: &mut [u8]) -> Result<(), IoError>;      // fills buf or errors
fn copy<R: Reader, W: Writer>(src: &mut R, dst: &mut W) -> Result<u64, IoError>; // no format-specific code needed
fn write_all<W: Writer>(w: &mut W, buf: &[u8]) -> Result<(), IoError>;

struct BufReader<R: Reader> { /* fixed-capacity ring, given an alloc.allocator or a caller-supplied &mut [u8] */ }
impl<R: Reader> BufReader<R> {
    fn with_capacity(inner: R, cap: usize, a: &dyn Allocator) -> Self;
    fn fill_buf(&mut self) -> Result<&[u8], IoError>;   // peek without consuming
    fn consume(&mut self, n: usize);
}
struct BufWriter<W: Writer> { fn with_capacity(inner: W, cap: usize, a: &dyn Allocator) -> Self; }

// Chaining / limiting combinators, no allocation:
struct Take<R: Reader> { fn new(inner: R, limit: u64) -> Self }   // caps a Reader to N bytes
struct Chain<R1: Reader, R2: Reader> { fn new(a: R1, b: R2) -> Self }
```

## Key design decisions
- `read`/`write` are single-method traits returning `usize`, not `[u8; N]`-filling or "read exactly" semantics by default — partial reads/writes are the norm (matches real socket/pipe behavior) and `read_full`/`write_all` are free functions layered on top, not separate trait methods, so implementers only ever write one method.
- `Seeker` is a separate trait from `Reader`/`Writer`, not a flag or capability query, so a type's seekability is visible in its type signature (a TCP socket simply never implements `Seeker`; a `File` implements all three).
- `BufReader`/`BufWriter` take an explicit `alloc.allocator` (or a caller-owned buffer) rather than allocating implicitly, keeping `sys.io` usable in constrained hosted environments and consistent with Principle 2's "no hidden allocation" even though `sys` itself is above the no-alloc boundary — buffering size should always be a caller decision, not a hidden default.
- No async variant lives here — `sys.io` is deliberately synchronous/blocking; `std.async` wraps these same trait shapes (or defines async-native equivalents) at the tier where cancellation and schedulers exist, keeping `sys` thin per Principle 5.

## Validated by applications
- **archive-cli**: streaming create/extract requires that `std.compress`'s deflate/zstd codecs accept *any* `sys.io` Writer as their sink and any Reader as their source, so compression never has to know whether it's writing into a file, a zip-entry framer, or a network socket. This is the direct test of Principle 3 against a format historically implemented as one monolithic library everywhere else — the naive design (a compressor that owns a `File` internally) was rejected specifically because it would have broken this app's "compress to any destination" requirement.
- **mp3-player**: the decoder must stream file bytes without loading whole tracks into memory, via `BufReader` over a `File`; this confirmed `read` needs to support partial reads gracefully rather than assuming a fixed block size, since decoders consume variable-length frames.
- **web-downloader**: HTTP response bodies are `Reader`s copied into files via `copy`, and this app is why `copy` returns `u64` bytes-transferred (needed for progress bars) rather than `()` — a naive first draft of `copy` returned nothing, which `std.cli`'s progress display could not have used.
- **process-supervisor** (Round 2): `sys.process::Child`'s `ChildStdout`/`ChildStderr` implementing `Reader` (and `ChildStdin` implementing `Writer`) directly is what lets the supervisor's log-rotation logic be `sys.io::copy` into a custom rotating `Writer` with zero glue code specific to "this Reader happens to be a child process" — the same `copy` this module already offered for files and archives, unmodified. See `modules/sys/process/API.md` for the full redirection design; recorded here as confirmation that Principle 3's composability held up for a stream source (a live child process) neither this module nor `sys.process` was originally designed with in mind together.

## Open questions / risks
Whether `IoError` should carry an `ErrorKind` enum (à la Rust) so callers can distinguish "would block," "interrupted," and "EOF" from real failures without string-matching — several apps (web-downloader's retry logic, chat-server's per-connection reads) need this distinction and it isn't fully specified here.
