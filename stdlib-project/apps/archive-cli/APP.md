# App: archive-cli (winzip-like)

A CLI archiving tool: `archive create out.zip file1 dir2/`, `archive extract out.zip -C dest/`, `archive list out.zip`, with support for zip and tar.gz, configurable compression level, optional password protection, and integrity verification.

## Why this is a good validation target
It is the direct, purpose-built exercise for `std.archive` and `std.compress`, and it's the second-strongest test (after `secrets-vault`) of `std.crypto` used for something other than TLS or hashing — password-protected zip requires key derivation plus authenticated encryption per entry.

## Features
- Create/extract/list zip and tar.gz archives.
- Streaming create/extract (don't require the whole archive in memory).
- Configurable compression level (store/fast/best).
- Optional password protection with authenticated encryption (not legacy ZipCrypto).
- `archive test` — verify integrity (checksums) without extracting.
- Preserve file permissions/mtimes on extract where the OS supports it.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.archive` | zip/tar container read & write |
| std | `std.compress` | deflate/zstd compression backing the archive formats |
| std | `std.crypto` | password-based key derivation + AEAD for encrypted entries; checksums for `archive test` |
| sys | `sys.fs` | walking directory trees to archive, creating extracted files/dirs with correct permissions |
| sys | `sys.io` | streaming compression instead of buffering entire files |
| std | `std.cli` | subcommands, progress display for large archives |
| core | `core.error` | corrupt archive, wrong password, unsupported format |
| alloc | `alloc.vec` | streaming buffers |

## Anticipated API stress points
`std.archive` and `std.compress` need a clean seam: archive formats should accept *any* `sys.io` reader/writer as their compression backend so `std.compress`'s codecs are reusable outside archiving too (e.g. compressing a single log file) rather than archive-format code embedding its own copy of deflate. This directly tests Design Principle 3 (small composable interfaces) against a real format that has historically been implemented as one monolithic library everywhere else.
