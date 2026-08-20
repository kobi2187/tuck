# App: backup-sync (rsync-lite)

A CLI directory synchronizer: `bsync source/ dest/` walks both trees, detects changed/new/deleted files (by size+mtime first, content hash on ambiguity), copies changed files, and supports `--exclude` patterns and a `--dry-run` report. A `--delta` mode does block-level rolling-checksum diffing for large files that changed only slightly (a video file with a metadata tweak, a database dump with a few new rows) instead of recopying the whole file.

## Why this is a good validation target
It's the strongest test yet of `sys.fs`'s change-detection story under real-world scale (large trees, large files) and it's the app that surfaces a genuine algorithmic gap: rsync's actual delta-transfer efficiency comes from a rolling (Adler-32-style) checksum that can be recomputed in O(1) as a byte window slides, which is a different primitive than the fixed-window cryptographic hashing `git-lite` and `secrets-vault` already validated.

## Features
- Recursive tree walk with `--exclude` glob patterns (reusing `std.regex::from_glob` from the git-lite round).
- Change detection: size+mtime fast path, content hash (`std.crypto`) fallback for ambiguous cases.
- Whole-file copy for new/fully-changed files; atomic replace (temp file + rename) so an interrupted sync never leaves a half-written destination file.
- `--delta` mode: rolling checksum over fixed-size blocks to find matching regions between old and new versions of a large file, transferring only the differing blocks.
- `--dry-run`: report what would change without touching the destination.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| sys | `sys.fs` | tree walking, metadata (size/mtime) comparison, atomic file replacement at scale |
| std | `std.crypto` | whole-file content hashing for ambiguous change detection |
| core | `core.hash` / **new primitive needed** | rolling checksum for block-level delta diffing — see validation note |
| std | `std.regex` | `--exclude` glob pattern matching, reusing `Regex::from_glob` |
| std | `std.cli` | dry-run report, progress across a large tree |
| std | `std.async` | parallel hashing/copying across many files |
| core | `core.error` | permission-denied files, broken symlinks — skip-and-report, not abort |

## Validation note: rolling checksums are a different primitive than anything validated so far
Every hash used in this project so far (`core.hash`'s FNV/SipHash, `std.crypto`'s SHA-256/BLAKE3) is a fixed-input, compute-once operation: hash this whole buffer, get one digest. A rolling checksum (the algorithm behind rsync's actual bandwidth savings, and behind rolling-hash-based chunking schemes like content-defined chunking in dedup/backup systems generally) needs to be incrementally *updatable* as a byte window slides one position at a time — `roll_in(new_byte)` / `roll_out(old_byte)` in O(1), not `recompute(whole_new_window)` in O(window size). This is a real, previously-unnamed API shape neither `core.hash` nor `std.crypto` currently offers. The resolution proposed in the module updates is a small addition to `core.hash` (not `std.crypto` — a rolling checksum for change-detection is explicitly not collision-resistant or attacker-resistant, so it belongs with the fast/non-cryptographic hashing module, matching the `core.hash`-vs-`std.crypto` boundary `git-lite` already established) — a `RollingChecksum` type with exactly the `roll_in`/`roll_out` shape.
