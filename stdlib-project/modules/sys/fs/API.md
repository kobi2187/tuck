# sys.fs

## Purpose
Wraps the OS filesystem: opening/creating files, directory traversal, path manipulation, permissions, atomic rename, and (optionally) change notification — thin enough to be a near-1:1 syscall mapping, with `File` implementing `sys.io`'s `Reader`/`Writer`/`Seeker`.

## Design lineage
Primarily Rust's `std::fs` (explicit `OpenOptions` builder, `Path`/`PathBuf` as a distinct owned/borrowed pair mirroring `core.str`/`alloc.string`) plus the `notify` crate for change-watching; Go's `os` package for the simplicity of its top-level `Open`/`Create`/`ReadDir` functions; Python's `pathlib` for path-manipulation ergonomics (joining, extension queries) without pulling in string-formatting magic.

## Proposed API
```
struct Path<'a> { .. }     // borrowed, core-tier string of path segments (platform-separator-aware)
struct PathBuf { .. }      // owned, alloc-tier

impl File {
    fn open(path: &Path) -> Result<File, FsError>;                       // read-only
    fn create(path: &Path) -> Result<File, FsError>;                     // create/truncate
    fn options() -> OpenOptions;                                         // builder for the rest
    fn sync_all(&self) -> Result<(), FsError>;                           // fsync: flushes content AND metadata (mtime, size, ...)
    fn sync_data(&self) -> Result<(), FsError>;                          // fdatasync-equivalent: flushes content only — see "Revision (kv-store-server)"
    fn set_len(&self, len: u64) -> Result<(), FsError>;                  // truncate/extend
    fn metadata(&self) -> Result<Metadata, FsError>;
}
impl Reader for File { .. }  impl Writer for File { .. }  impl Seeker for File { .. }

struct OpenOptions { .. }
impl OpenOptions {
    fn read(self, v: bool) -> Self;
    fn write(self, v: bool) -> Self;
    fn append(self, v: bool) -> Self;
    fn create(self, v: bool) -> Self;
    fn create_new(self, v: bool) -> Self;   // fail if exists — the atomic-create primitive
    fn truncate(self, v: bool) -> Self;
    fn open(self, path: &Path) -> Result<File, FsError>;
}

fn rename(from: &Path, to: &Path) -> Result<(), FsError>;   // atomic on same filesystem — the resumable-download/atomic-write primitive
fn remove_file(path: &Path) -> Result<(), FsError>;
fn create_dir_all(path: &Path) -> Result<(), FsError>;
fn read_dir(path: &Path) -> Result<DirIter, FsError>;       // yields DirEntry, lazily (core.iter-compatible)
fn metadata(path: &Path) -> Result<Metadata, FsError>;

struct DirEntry { .. }
impl DirEntry {
    fn path(&self) -> PathBuf;
    fn file_name(&self) -> &str;
    fn file_type(&self) -> Result<FileType, FsError>;   // cheap: from the OS's raw directory-stream record where available
    fn metadata(&self) -> Result<Metadata, FsError>;     // see "Revision (backup-sync)" — cheaper than fs::metadata(entry.path()), not free on every platform
}
fn set_permissions(path: &Path, perm: Permissions) -> Result<(), FsError>;

struct Watcher { fn new() -> Result<Watcher, FsError>; }
impl Watcher {
    fn watch(&mut self, path: &Path, recursive: bool) -> Result<WatchId, FsError>;
    fn poll(&mut self) -> Result<Vec<FsEvent>, FsError>;   // or a Reader-like blocking `next_event`
}
enum FsEvent { Created(PathBuf), Modified(PathBuf), Removed(PathBuf), Renamed(PathBuf, PathBuf) }
```

## Key design decisions
- `create_new` (fail-if-exists) is a first-class `OpenOptions` flag rather than a "check exists, then create" pattern the app has to hand-roll — TOCTOU-safety by construction, needed by every app that does atomic writes.
- `rename` is documented as atomic *only within the same filesystem*, and the module does not silently fall back to copy+delete across filesystems — a wrong fallback here would silently break every app relying on rename for crash-safety, so `sys.fs` fails loudly with `FsError::CrossDevice` instead and leaves the copy+delete decision to the caller (or `std`-tier helpers).
- `Watcher` is genuinely optional/best-effort: some OS/filesystem combinations (network mounts, some embedded filesystems) don't support native notification, and the API returns `FsError::Unsupported` from `Watcher::new` rather than silently degrading to polling, so callers make an explicit choice.
- `read_dir` returns a lazy iterator, not a materialized `Vec<DirEntry>`, so `log-grep`'s directory-tree walk over potentially huge trees doesn't force a full listing into memory before the first match can be reported.
- `DirEntry::metadata()` is a method on the entry, not a requirement to call the top-level `fs::metadata(path)` function again — this is a deliberate, narrower promise than "metadata comes free with every directory listing" (see "Revision (backup-sync)" for why the stronger promise can't honestly be made cross-platform), but it does guarantee the entry-scoped call never re-resolves the full path from the filesystem root the way a fresh `fs::metadata(entry.path())` call would.

**Revision (backup-sync):** `DirEntry` gained explicit `file_type()` and `metadata()` methods, and the module now documents their cost honestly instead of leaving `DirEntry`'s shape unspecified (the original sketch only said `read_dir` "yields `DirEntry`" with no methods listed — checking it against backup-sync's requirement surfaced that gap). backup-sync's change-detection fast path (size+mtime comparison across trees with thousands to millions of entries) is exactly the case where "one `stat`-class call per file, unavoidably" versus "metadata already in hand from the directory listing" is the difference between a sync that's usable and one that isn't at scale. The honest resolution, checked against how `readdir`/`getdents` and `FindFirstFile`/`NtQueryDirectory` actually behave, is platform-asymmetric and documented as such rather than papered over with a uniform promise: on Windows, the directory-enumeration syscall itself returns file size and both mtime and creation time inline, so `DirEntry::metadata()` there is genuinely free — no second syscall. On POSIX, `readdir`/`getdents64` does not carry size or mtime in its record (only name and, on most modern filesystems, a `d_type` hint good enough for a cheap `file_type()`); `DirEntry::metadata()` there still costs one `fstatat()` per entry, resolved *relative to the already-open directory file descriptor* rather than by re-walking the full path from `/` the way calling top-level `fs::metadata(entry.path())` for every entry would — so it is real syscall-per-entry cost (the report should not claim otherwise), but it is the cheapest form that cost can take on POSIX, and it's strictly better than the alternative naive pattern (`read_dir` for names, then a second full-path `metadata()` call per entry) that forces path resolution twice. `DirEntry::file_type()` is kept as a separate, near-free method from `metadata()` specifically because backup-sync's walk needs "is this a file, dir, or symlink" for every entry regardless of whether the size/mtime fast path later needs a real `metadata()` call — most entries where the fast path already indicates "unchanged" from a prior run's cached listing never need `metadata()` at all, only `file_type()`. No separate `read_dir_with_metadata` variant was added: given the POSIX asymmetry above, a function promising bundled metadata would be misleading half the time, so the entry-scoped `.metadata()` method (cheapest-available-on-the-platform, explicit call, explicit cost) was judged the more honest API than a name implying a free lunch that only Windows actually offers.

**Revision (kv-store-server):** `File::sync_data()` was added, distinct from the existing `sync_all()`. Before this app, the atomic-write story validated by `web-downloader`/`secrets-vault`/`todo-cli` was exclusively a *whole-file-rewrite* pattern: write a temp file, `sync_all()` once, `rename()` into place — an occasional operation where the extra cost of `fsync`-equivalent (flushing inode metadata — mtime, size — in addition to file content) is negligible. kv-store-server's write-ahead log is the opposite shape: every single mutating command (`SET`/`DEL`/`INCR`/...) appends a few bytes and, under the strictest durability policy, must be fsync'd *before acknowledging the client* — thousands of times a second. Checking whether the existing design supported this: `OpenOptions::append` plus `Writer::write` already gives cheap, position-safe appends with no whole-file-rewrite (confirmed adequate, no change needed there). But the only sync primitive available was `sync_all()`, which on every real OS also flushes the file's metadata (mtime, size) to stable storage on every call — for a WAL, the file's size/mtime changing on every append is exactly the metadata churn `fdatasync` exists to let you skip, and forcing every high-frequency append through full `fsync` semantics would make the "fsync every write" durability policy needlessly and often prohibitively slower than it has to be (roughly double the durability-critical I/O per append on filesystems where metadata and data journal separately). `sync_data()` closes that gap: content-only durability, explicit and per-call, exactly the "cheap, explicit, per-call choice" this app's WAL needs — `sync_all()` remains available and correct for the whole-file-rewrite/rename pattern where metadata durability (the new file's size being observable after a crash) actually matters.

## Validated by applications
- **web-downloader**: the resumable-download requirement is the direct forcing function for `OpenOptions::append` plus `File::set_len` — a cancelled download must leave a byte-exact partial file, and `rename` (temp file → final name) is what makes "download complete" atomic rather than observable-mid-write. This confirmed atomic rename needed to be a top-level `sys.fs` function, not something apps reconstruct from `remove`+`link`.
- **secrets-vault**: "write to temp file, fsync, rename" is this app's entire crash-safety story, which is why `File::sync_all` and `rename` are both explicit, separate, callable steps rather than folded into a single "safe write" helper — the app needs to control exactly when fsync happens relative to encryption, so a black-box helper would have been the wrong abstraction.
- **log-grep**: directory-tree walking with `.gitignore`-style exclusion is why `read_dir` must be a lazy, `core.iter`-compatible stream rather than an eager listing — a repo with hundreds of thousands of files must not pay an up-front directory-scan cost before the first result streams out.
- **todo-cli**: the append-only undo log wants "append, then fsync" to be trivial and safe without manual offset bookkeeping, which `OpenOptions::append` plus `Writer::write` (append mode makes every write atomic-at-the-OS-level w.r.t. position) directly provides without new API surface.
- **kv-store-server** (Round 2): the sharpest durability test in the project so far — see "Revision" above for `sync_data()`. This app also confirms the *append* half of the design (already validated by `todo-cli`) generalizes to a much higher call frequency and a stricter correctness bar: WAL replay after a simulated crash must never apply a truncated/torn last record, which is a property of how the app frames each WAL entry (length-prefixed, checked on replay — a `std.encoding`/app-level concern) composed with `sys.fs` guaranteeing that a `sync_data()` call that returned `Ok` really did make prior `write()`s durable — `sys.fs` doesn't invent new guarantees here, it just needed the cheaper primitive to make relying on those guarantees at this frequency practical.
- **process-supervisor** (Round 2): secondary — log-file rotation (size- or time-based) is implemented entirely with existing `sys.fs` surface (`File::metadata().len()` to check the size threshold, `File::create` for the new segment, `rename` to move a completed segment aside) plus `sys.io::copy` from the child's piped stdout (see `modules/sys/process/API.md`). No new `sys.fs` API was needed for this; recorded here as confirmation, not a revision.
- **backup-sync** (Extension round 3): forced `DirEntry` to actually be specified (see "Revision" above) rather than left as an unstated implementation detail — a genuine, previously-hidden gap this app's scale requirement (thousands to millions of files) exposed that no prior app's tree-walk (`log-grep`, whole-repo but match-and-stop-early; `git-lite`, per-object not per-directory-listing) happened to stress. The atomic-replace side of this app (temp file + `rename` so an interrupted sync never leaves a half-written destination) needed no change at all — it's the exact same pattern `web-downloader`/`secrets-vault`/`git-lite` already validated, just run once per changed file instead of once per whole download; `create_new`'s TOCTOU-safety and `rename`'s same-filesystem atomicity guarantee both hold unchanged at this higher call frequency, since neither's cost or correctness scales with tree size, only with number-of-changed-files, which `--delta` mode (a `std`/app-level concern, not a `sys.fs` one) is what actually bounds.
- **git-lite** (Extension round 2): secondary — a content-addressed object store is a genuinely different *shape* of `sys.fs` usage than any prior app: thousands of small, immutable files under a two-level hash-prefix directory layout (`.gl/objects/ab/cdef1234…`), rather than one archive/log/database file. `create_dir_all` (create the two-character prefix subdirectory the first time an object with that prefix appears) and the existing "write to temp, `create_new`/`rename` into place" atomic-write pattern (already validated by `web-downloader`/`secrets-vault`) compose without any new API to give write-once, collision-safe object storage — a rename onto an existing path is simply never attempted, since content addressing means a colliding filename implies identical content and the write can be skipped after a cheap `metadata()`/`open()` existence check. `HEAD`/branch refs (small files whose content is swapped atomically on `commit`/`checkout`) are the same temp-write-then-`rename` pattern `secrets-vault` and `todo-cli` already exercised, just applied to many tiny files instead of one. No revision: the existing surface was sufficient, but this is the first app to validate `create_dir_all` by name, and the first to validate the "write-once content-addressed store" access pattern specifically.

## Open questions / risks
`Watcher`'s cross-platform event semantics (inotify vs. kqueue vs. ReadDirectoryChangesW) genuinely differ in what "renamed" and "modified" mean; this API sketch resolves it as a lowest-common-denominator enum, which may need per-platform escape hatches later. Permission representation (`Permissions`) also needs to reconcile POSIX mode bits with Windows ACL-flavored permissions without picking a POSIX-only design by accident.
