# sys.mmap

## Purpose
Memory-mapped files and anonymous/shared memory: maps a file (or an anonymous region) directly into the process's address space as a byte slice, avoiding explicit read() calls for large or randomly-accessed data.

## Design lineage
Modeled on Rust's `memmap2` crate (the de facto standard third-party crate that Rust's own `std` deliberately omits — this proposal takes the position that `sys.mmap` belongs in the standard library itself, since two of the eleven validating apps need it and hand-rolling `mmap`/`MapViewOfFile` FFI per-app is exactly the kind of foundational-but-fiddly systems code a stdlib should absorb) over raw POSIX `mmap`/`munmap` and Windows `CreateFileMapping`/`MapViewOfFile`, which the API must reconcile into one portable shape.

## Proposed API
```
struct Mmap { .. }             // read-only mapping, derefs to &[u8]
impl Mmap {
    fn open(file: &File) -> Result<Mmap, MmapError>;                       // maps whole file, read-only
    fn open_range(file: &File, offset: u64, len: usize) -> Result<Mmap, MmapError>;
    fn as_slice(&self) -> &[u8];
    fn advise(&self, hint: Advice) -> Result<(), MmapError>;               // madvise-equivalent: Sequential, Random, WillNeed
}
struct MmapMut { .. }          // writable mapping, derefs to &mut [u8]
impl MmapMut {
    fn open_rw(file: &File) -> Result<MmapMut, MmapError>;
    fn map_anon(len: usize) -> Result<MmapMut, MmapError>;                 // no backing file — scratch shared memory
    fn as_mut_slice(&mut self) -> &mut [u8];
    fn flush(&self) -> Result<(), MmapError>;                              // msync-equivalent, blocking
    fn flush_async(&self) -> Result<(), MmapError>;
    fn make_read_only(self) -> Result<Mmap, MmapError>;                    // mprotect down, cheap re-view
}
struct SharedMem { .. }        // named/anonymous shared memory for IPC, not backed by a visible filesystem path
impl SharedMem {
    fn create(name: &str, len: usize) -> Result<SharedMem, MmapError>;
    fn open(name: &str) -> Result<SharedMem, MmapError>;
    fn as_mut_slice(&mut self) -> &mut [u8];
}
enum Advice { Normal, Sequential, Random, WillNeed, DontNeed }
```

## Key design decisions
- `Mmap` (read-only) and `MmapMut` (read-write) are distinct types rather than one type with a runtime mutability flag — mirroring the `Reader`/`Writer` split in `sys.io`, this makes a function's aliasing/mutation contract visible in its signature (a function taking `&Mmap` provably cannot mutate the backing file) rather than a runtime check.
- `Mmap::as_slice()` returns an ordinary `&[u8]`, deliberately making the mapped region a first-class byte slice usable by every `core.slice`/`core.iter` function with zero wrapper code — this is the module's direct contribution to Principle 3: a memory-mapped file must compose with the same iterator adapters as any in-memory buffer, or the mapping is pointless overhead.
- `advise()` (madvise) is exposed as an explicit, optional hint rather than something the module guesses at internally — sequential-scan workloads (log-grep) and random-access workloads (index-lookup-style access) benefit from opposite hints, and only the caller knows which pattern applies.
- The API does not hide the platform-specific danger that a mapped file being truncated or removed out from under a live mapping is undefined/signal-raising behavior on POSIX (`SIGBUS`) — this is documented as a caller responsibility (don't mmap files another process might truncate without coordination) rather than silently "solved" with an unenforceable promise, since no portable API can fully close this gap without a performance cost the module's users (log-grep, mp3-player) wouldn't accept.

## Validated by applications
- **log-grep**: the primary validation target, explicitly named in the report's framing ("whether `core.iter` layers over an mmap'd region with zero copies"). Mapping large files instead of `read()`-ing them in chunks is the app's whole performance thesis; this confirmed `Mmap::as_slice()` must return a plain `&[u8]` (not a custom `MappedBytes` wrapper type) specifically so `core.iter`'s line-splitting adapters and `std.regex`'s matcher can consume it with the exact same code path they'd use on an in-memory `Vec<u8>` — any wrapper type would have forced either a copy or bespoke iterator adapters, defeating the app's stated performance goal. `advise(Advice::Sequential)` is directly motivated by this app's access pattern (scanning start-to-end).
- **mp3-player**: mapping large audio files instead of chunked reads is listed as a distinct usage from `sys.io`'s streaming reads (the app uses both, for different files/situations) — this confirmed `Mmap::open_range` is needed (not just whole-file mapping), since seeking to an arbitrary point in a large FLAC file and mapping only the needed region avoids paging in an entire multi-hundred-megabyte file for a single seek operation, a refinement the naive whole-file-only `open()` design didn't cover.

## Open questions / risks
`SharedMem` (named shared memory for IPC) is speculative — no validating app in this set uses cross-process shared memory, so its API shape above is modeled on the general POSIX/Windows primitive rather than proven against a concrete usage pattern, and it's the part of this module most likely to need revision. The SIGBUS-on-truncation hazard above is also a real risk this design documents rather than solves.
