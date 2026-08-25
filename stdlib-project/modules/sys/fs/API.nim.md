# sys.fs — Nim API

## Purpose
Files and folders: open one, read or write it, make it survive a crash, walk a directory tree, move something into place atomically. Thin enough that each proc is one syscall you can name.

## Protocols implemented
`File` is `Resource` + `Streamable` (+ `sys.io`'s `Seekable`); `Folder` is `Collection[Entry]` — per PROTOCOLS' assignment table.

## The API

```nim
type
  Path* = distinct Text        ## owned; `converter` from string literals, so `open("notes.txt")` works
  Access* = enum
    Reading                    ## must exist
    Writing                    ## create, truncate
    Appending                  ## create, every write lands at the end, atomically
    Updating                   ## read and write, no truncate
  File* = object               ## Resource + Streamable + Seekable
  Folder* = object             ## Collection of Entry
  Entry* = object
    name*: TextView
    kind*: EntryKind           ## File, Folder, Link — near-free, straight off the directory record
  FileInfo* = object
    bytes*: int64
    changedAt*, madeAt*: Timestamp
    permissions*: Permissions

proc open*(path: Path; how = Reading; mustBeNew = false): File
  ## `mustBeNew = true` is the atomic create — fails if the path exists, with no
  ## check-then-create window. Raises `IoFailure`; see `tryOpen`.
proc tryOpen*(path: Path; how = Reading; mustBeNew = false): Option[File]
proc open*(f: var File): bool      ## Resource: reopen the same path — this is what `retry(f, 3, 100.ms)` calls
proc close*(f: var File)           ## idempotent
proc isOpen*(f: File): bool

proc persist*(f: File; metadata = true)
  ## Make prior writes survive a crash. `metadata = true` is fsync (content + size + mtime);
  ## `metadata = false` is fdatasync — content only, roughly half the durability-critical I/O,
  ## which is what a per-append write-ahead log wants thousands of times a second.
proc resize*(f: var File; bytes: int64)     ## truncate or extend
proc info*(f: File): FileInfo

proc rename*(path: Path; to: Path)
  ## Atomic within one filesystem. Across filesystems it raises `CrossDevice` rather than
  ## silently degrading to copy-then-delete, which would quietly break every crash-safe rename.
proc remove*(path: Path; recursive = false)
proc makeFolder*(path: Path; parents = true)
proc info*(path: Path): FileInfo
proc has*(path: Path): bool                 ## never raises

proc openFolder*(path: Path): Folder
iterator list*(f: Folder): Entry            ## the Collection primitive; lazy, one getdents at a time
iterator walk*(root: Path; recursive = true; followLinks = false): Entry
proc path*(e: Entry): Path
proc info*(e: Entry): FileInfo
  ## Honest cost: free on Windows (the enumeration syscall already carried size and mtime);
  ## one `fstatat` against the open folder handle on POSIX — cheaper than `info(e.path())`,
  ## which would re-resolve the path from the root, but not free. `e.kind` is free on both.

type Watcher* = object                      ## Resource
proc openWatcher*(): Watcher                ## raises `Unsupported` where the OS has no notifications
proc watch*(w: var Watcher; path: Path; recursive = false)
proc receive*(w: var Watcher; timeout = Forever): Option[Change]
type Change* = object
  kind*: ChangeKind                         ## Created, Modified, Removed, Renamed
  path*, wasPath*: Path

type Lock* = object                         ## Resource. Advisory, whole-file — `flock`/`LockFileEx`
proc lock*(path: Path): Lock
  ## Blocks until acquired. The common single-instance-app case: one call,
  ## held for the process's whole lifetime, released by `close` or process
  ## exit — whichever comes first, which is the entire point of an advisory
  ## lock over a plain "does this file exist" check racing at startup.
proc tryLock*(path: Path): Option[Lock]
  ## Absent immediately if another process already holds it — the shape a
  ## "second copy is already running" check actually wants; `lock` would
  ## make that check block on itself.
proc close*(l: var Lock)                    ## idempotent, releases early if held past its need
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `OpenOptions` builder (7 methods) | `open(path, how, mustBeNew =)` | one call, one enum, one named flag. The builder existed to express combinations nobody uses |
| `create_new(true)` | `mustBeNew = true` | states the requirement, not the syscall flag |
| `sync_all` / `sync_data` | `persist()` / `persist(metadata = false)` | the split is kept as a per-call choice; one verb, and the cheap path is visibly the cheap path |
| `set_len` | `resize` | same word `alloc.allocator` uses for the same idea |
| `read_dir` → `DirIter` | `openFolder` → `Folder.list()` | `Folder` is a `Collection`, so `first`, `count` and `each` arrive free |
| `DirEntry` | `Entry` | inside a `Folder` the "Dir" was noise |
| `metadata()` | `info()` | what a person calls it; `FileInfo` is also Nim's own word |
| `remove_file` / `remove_dir_all` | `remove(path, recursive =)` | one verb, one option |
| `create_dir_all` | `makeFolder(path, parents = true)` | the common case is the default |
| `Watcher::poll -> Vec<FsEvent>` | `receive(w, timeout)` | the vocabulary's await-a-message verb; `sys.signal` reads identically |
| `flock(fd, LOCK_EX \| LOCK_NB)` | `tryLock(path)` | one call instead of a raw syscall plus flag arithmetic; `Option` where the OS returns `EWOULDBLOCK` |

## In use

```nim
# backup-sync: the change-detection fast path, one cheap call per entry
for e in walk(source):
  if e.kind != File: continue
  let mine = e.info()                       # cheapest form the platform offers
  let theirs = cache.get(e.name)
  if theirs.isNone or theirs.get().bytes != mine.bytes or theirs.get().changedAt != mine.changedAt:
    copyFileAtomically(e.path(), dest / e.name)

# kv-store-server: append a WAL record and acknowledge only once it's durable
var wal = open("data/wal.log", Appending)
wal.writeAll(frame(cmd))
wal.persist(metadata = false)               # fdatasync — the whole reason the split exists
client.writeAll(OkReply)

# a desktop app (per DOMAINS.md): refuse to start a second copy of itself
tryLock(appDataDir() / "app.lock").ifSome(guard):
  runApp()
  close(guard)
do:
  echo "already running"; quit(1)
```

## Vocabulary exceptions
- **`remove(path)` returns nothing**, unlike the table's `remove(target, key) -> Option[V]`. The OS does not hand back what it deleted, and inventing a value to return would be a lie.
- **`persist`, `rename`, `walk` and `watch` are domain verbs.** Durability, atomic relinking and tree traversal have no structural analogue; each takes its subject first and its options last.
- **`Watcher` uses `receive` without being a `Messenger`.** Nothing ever sends to it. Borrowing the one right verb beats inventing `nextEvent`.
- **`Lock` is advisory, not mandatory.** It only stops another process that also calls `lock`/`tryLock` on the same path — it does not prevent an unrelated program from reading or writing the file underneath it. That's the real semantics of `flock`/`LockFileEx` on every OS this wraps, and pretending otherwise would be the "hidden control flow" mistake `REPORT.md`'s Zig citation already warns against. *(Specified in `DOMAINS.md`'s Extension round 4 — the single-instance-lock gap, desktop domain.)*
