# App: git-lite (mini content-addressed version control)

A small version control tool in the spirit of early git: `gl init`, `gl add file.txt`, `gl commit -m "msg"`, `gl log`, `gl checkout <hash>`. Objects (blobs, trees, commits) are content-addressed by hash and stored compressed in a local object store; a commit graph tracks parent pointers.

## Why this is a good validation target
It is the purpose-built exercise for `core.hash`/`std.crypto` used for content addressing — a materially different use of hashing than anything validated so far (dedup keys, checksums, or MAC keys). It also directly tests `std.compress` used for small, individually-compressed blobs rather than one big archive stream, and `alloc.map` as a commit graph (parent-pointer traversal, not just a lookup table).

## Features
- `init`: create the object store and refs directory.
- `add`/`commit`: hash file contents (blob), hash a directory listing (tree), hash a commit object (message, tree hash, parent hash(es), timestamp) — each stored compressed, named by its own hash.
- `log`: walk the commit graph from HEAD via parent pointers.
- `checkout <hash>`: reconstruct a tree of files from stored blobs.
- `.gitignore`-style exclude patterns when computing what `add` should include.

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| std | `std.crypto` | content-addressing hash (SHA-256, not a fast/non-cryptographic hash — collision resistance matters for object identity) |
| std | `std.compress` | per-object compression before writing to the object store |
| std | `std.encoding` | binary encoding of tree/commit objects (structured records referencing other hashes) |
| alloc | `alloc.map` | commit graph (hash → commit object), tree structure (name → hash) |
| sys | `sys.fs` | object store layout (hash-prefixed directories), refs (HEAD, branch pointers) as small files |
| std | `std.regex` | `.gitignore`-style pattern matching |
| std | `std.chrono` | commit timestamps |
| core | `core.hash` | **contrast case** — the commit graph's in-memory `alloc.map` lookups use `core.hash`'s fast non-cryptographic hash, while object identity uses `std.crypto`'s SHA-256; the app is a clean demonstration of why those are two different modules, not one |
| core | `core.error` | corrupt object detection (hash of decompressed content doesn't match its filename) |

## Anticipated API stress points
This app is the cleanest test yet of whether `std.crypto`'s hashing API and `core.hash`'s hashing API are actually distinguishable in practice by a working developer, or whether having two "hash" modules in different tiers is itself a source of confusion — a real design risk worth naming, not just an opportunity. It also tests whether `std.compress`'s codecs have low enough per-call overhead to compress thousands of small objects individually (git's actual object model) rather than being tuned only for `archive-cli`'s few-large-files case.
