# std.archive — Tuck translation

## Shape decision
Freeform `pending:` over an `{id: int}` archive handle, matching the `sys`
tier's handle convention. **Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type ArchiveError:
  | NotAnArchive
  | EntryNotFound
  | BadPassword

type ArchiveEntry = {name: str, bytes: i64, isFolder: bool, modifiedMs: u64}

pending:
  fn openArchive({path: str}) -> !{id: int} [io, error: ArchiveError]
  fn listEntries({id: int}) -> !{entries: Seq[ArchiveEntry]} [io, error: ArchiveError]
  fn extractTo({id: int, name: str, destPath: str}) -> !void [io, error: ArchiveError]
  fn createArchive({path: str, how: Method}) -> !{id: int} [io, error: ArchiveError]
  fn addEntry({id: int, name: str, sourcePath: str}) -> !void [io, error: ArchiveError]
  fn closeArchive({id: int}) -> void [io]
```

## Notes
- **Handle-based, because an archive is an open file with an index** — the
  same reasoning as `std.regex`'s compiled pattern and `std.db`'s
  connection. Nothing about it wants to be a Tuck value.
- **`extractTo`/`addEntry` work path-to-path** rather than through streams,
  for the same reason `std.compress` lost its streaming form. This is the
  right shape *anyway* for the common case (extracting a zip to a folder),
  but it means a caller can't post-process entry bytes in flight without a
  temp file.
- **`BadPassword` is a real variant** — `archive-cli`'s encryption support
  means a wrong passphrase is an expected outcome, not an exceptional one,
  and it must be distinguishable from a corrupt archive.
- **Path traversal ("zip slip") is not expressible as a type.**
  `extractTo` taking a destination path means the implementation must
  reject entries whose names escape it (`../../etc/passwd`). Nothing in the
  signature enforces that; it's an implementation obligation worth stating
  loudly, since it is the classic archive vulnerability.
