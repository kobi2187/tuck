# sys.fs — Tuck translation

## Shape decision
Freeform `pending:` verbs over an **`fd: int` handle**, matching the real
`std/net.tuck` precedent exactly (`listen`/`accept`/`recv` all pass
`fd: int`). **Compiler-verified**, `./tuck ch`: `OK`.

## Why a handle rather than a `File` object

The Nim design had `File` as a `Resource + Streamable + Seekable` object.
Two Tuck facts push toward the flat handle instead:

1. **A `File` holding an OS handle is fine as a record, but an opaque
   *extern* handle is not storable at all** (`FRICTIONS.md` #7). Since the
   real implementation binds C/Nim I/O, the value that crosses is an
   integer descriptor anyway.
2. **`std/net.tuck` already made this call** for sockets and reads well:
   `{fd: sock, max: 4096} recv`. Matching it keeps one convention for all
   OS resources rather than two.

`Streamable`/`Seekable` (from `sys.io`) are then attached to whatever
wrapper a caller wants via top-level `satisfies`, rather than being baked
into a type this module owns.

## The API

```tuck
type FsError:
  | NotFound
  | AccessDenied
  | AlreadyExists
  | NotEmpty
  | CrossDevice
  | IoFailed

type Access:
  | Reading
  | Writing
  | Appending
  | Updating

type EntryKind:
  | IsFile
  | IsFolder
  | IsLink

type Entry = {name: str, kind: EntryKind}
type FileInfo = {bytes: i64, changedAt: u64, madeAt: u64}
type ChangeKind:
  | Created
  | Modified
  | Removed
  | Renamed
type Change = {kind: ChangeKind, path: str, wasPath: str}

pending:
  fn open({path: str, how: Access, mustBeNew: bool}) -> !{fd: int} [io, error: FsError]
  fn close({fd: int}) -> void [io]
  fn persist({fd: int, metadata: bool}) -> !void [io, error: FsError]
  fn resize({fd: int, bytes: i64}) -> !void [io, error: FsError]
  fn infoOf({fd: int}) -> !FileInfo [io, error: FsError]

  fn rename({path: str, to: str}) -> !void [io, error: FsError]
  fn remove({path: str, recursive: bool}) -> !void [io, error: FsError]
  fn makeFolder({path: str, parents: bool}) -> !void [io, error: FsError]
  fn infoOfPath({path: str}) -> !FileInfo [io, error: FsError]
  fn has({path: str}) -> bool [io]

  fn list({path: str}) -> !{entries: Seq[Entry]} [io, error: FsError]
  fn walk({root: str, recursive: bool}) -> !{entries: Seq[Entry]} [io, error: FsError]

  fn lock({path: str}) -> !{fd: int} [io, error: FsError]
  fn tryLock({path: str}) -> {fd: int}? [io]

  fn openWatcher() -> !{fd: int} [io, error: FsError]
  fn watch({fd: int, path: str, recursive: bool}) -> !void [io, error: FsError]
  fn nextChange({fd: int, timeoutMs: u32}) -> Change? [io]
```

## Notes
- **`Path` collapses to `str`.** The Nim design made it `distinct Text` for
  type safety; `std/fs.tuck` (the real one) already uses plain `str`, and
  adding a distinct type here would diverge from working code for a benefit
  Tuck's payload-binding already partly supplies.
- **`persist(metadata:)` keeps the fsync/fdatasync split**, which was a
  round-1 finding driven by `kv-store-server`'s WAL — the cheap path stays
  visibly cheap.
- **`lock`/`tryLock` carry over** the round-4 addition (desktop
  single-instance), with `tryLock` returning `?{fd}` — absence is "someone
  else holds it," which is a normal outcome, not an error. Matches the
  `pool.acquire` precedent exactly.
- **`list`/`walk` return `Seq[Entry]` rather than iterating.** Honest about
  allocation per the tier ruling; a lazy form needs the iterator/callback
  question settled (`FRICTIONS.md` #1).
- **`nextChange` replaces `Watcher.receive`** — `receive` is `Messenger`'s
  verb and nothing is ever sent *to* a watcher, which the Nim design
  already flagged as a borrowed word. With no protocol machinery to satisfy
  here, the plain name is better.
