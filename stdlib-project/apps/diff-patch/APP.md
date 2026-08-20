# App: diff-patch

A CLI implementing the classic pair: `difftool a.txt b.txt` prints a unified diff; `patchtool a.txt < changes.diff` applies it. Supports context lines, hunk headers, and a `--check` mode that verifies a patch applies cleanly without writing output.

## Why this is a good validation target
This is the purest algorithmic app in the set — the interesting work (longest-common-subsequence / Myers diff) lives entirely in `core`/`alloc`, with almost no `sys` or `std` involvement beyond reading two files and parsing one text format. It is the best test of whether `core.iter`, `core.cmp`, and `alloc.vec` compose well enough for a genuinely non-trivial algorithm to be pleasant to write, and it gives `std.testing` its best property-testing case yet: `apply(diff(a, b), a) == b` for arbitrary text.

## Features
- Line-based diff using an LCS/Myers-style algorithm, output as unified diff format (`---`/`+++`/`@@` hunk headers, context lines).
- Patch application: parse unified diff format, apply hunks to a source file, detect and report non-applying hunks (offset search within a small fuzz window, like real `patch`).
- `--check`: dry-run validation without writing.
- Byte-identical round-trip guarantee as the core correctness property.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| core | `core.iter` | the diff algorithm is fundamentally iterator/slice manipulation — longest-common-subsequence over two sequences |
| core | `core.cmp` | line-equality comparison driving the LCS table |
| alloc | `alloc.vec` | the LCS/edit-script working storage |
| alloc | `alloc.string` | line splitting/joining, hunk text assembly |
| std | `std.encoding` | parsing/generating the unified diff text format — **a new format std.encoding doesn't currently name** |
| std | `std.testing` | the primary validation target: property-based round-trip testing (`apply(diff(a,b), a) == b`) across randomly generated text pairs |
| sys | `sys.fs` | reading the two input files / the patch file |
| core | `core.error` | malformed patch syntax, hunk that doesn't apply (context mismatch) |

## Anticipated API stress points
Unified diff format is plain structured text but isn't JSON/TOML/CSV/XML/binary — this app is a second data point (after `podcast-subscriber`'s XML and this round's `git-lite`) that `std.encoding`'s format list is going to keep growing as real apps are considered, which is itself a finding about the module's scope worth addressing head-on rather than case-by-case. On the algorithmic side, the real test is whether `core.iter`'s adapters (windows, chunking, zip) are expressive enough to implement Myers diff without dropping to manual index arithmetic — a concrete, checkable claim rather than a vague one.
