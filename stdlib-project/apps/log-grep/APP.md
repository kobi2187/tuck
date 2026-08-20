# App: log-grep

A `grep`/`ripgrep`-lite CLI: search one or many files (or a directory tree) for a regex pattern, print matching lines with file/line-number context, support `-i`/`-v`/`-c`/`--count`, and parallelize across large files/many files for speed. A secondary mode reads structured (JSON-lines) logs and filters by field.

## Why this is a good validation target
It is the primary exercise for `std.regex`'s "linear-time, no catastrophic backtracking" design claim under adversarial-looking real input, and for whether `sys.fs`/`sys.mmap`/concurrency compose cleanly for a classic "many independent chunks of read-only work" parallelism shape — a different concurrency pattern than `chat-server`'s long-lived connections or `web-downloader`'s N-way network fan-out.

## Features
- Regex search across files/directories, with `.gitignore`-style exclude support.
- Case-insensitive, invert-match, count-only, and line-number-context modes.
- Parallel scan across files (and, for very large single files, across chunks of one file).
- Unicode-aware matching (case folding that's correct beyond ASCII).
- Secondary JSON-lines field-filter mode (`log-grep --json level=error`).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.regex` | the core matching engine — the app is a direct stress test of its performance guarantees |
| sys | `sys.fs` | directory tree walking, exclude-pattern matching |
| sys | `sys.mmap` | mapping large files instead of read()-ing them, for scan speed |
| std | `std.async` / `sys.thread` | parallel scan across files/chunks with a shared result-aggregation point |
| std | `std.i18n` | Unicode-correct case folding for `-i` |
| std | `std.encoding` | JSON-lines parsing for the structured-log mode |
| std | `std.cli` | argument parsing, colored match highlighting |
| core | `core.iter` | streaming line-by-line iteration over mapped file content without extra copies |
| core | `core.error` | permission-denied files, binary-file detection/skip |

## Anticipated API stress points
This app tests whether `core.iter`'s lazy adapters can be layered directly over an `sys.mmap`-backed byte region with zero copies down to `std.regex`, or whether the layers force at least one buffer copy somewhere — a concrete, measurable answer to how well Design Principle 3 (composable interfaces) holds up under a performance-sensitive real workload rather than a toy one.
