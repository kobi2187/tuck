# sys.mmap — Tuck translation

## Does not translate as designed, and the reason is its whole point.

`sys.mmap`'s value proposition was stated exactly: *"What you get back is
an ordinary `View[byte]`, so every `core.iter` adapter and every
`std.regex` matcher works on it with no wrapper and no copy."*

The zero-copy borrowed window is the product. Tuck has no `View[T]` (see
`core.slice`) and forbids storing the pointer a mapping *is*, so what comes
back can only be a `Seq[u8]` — a copy. A memory-mapped file you have to
copy out of is just a slower `readFile`.

## What survives, and what it's for

The mapping still has two uses that don't depend on handing Tuck a borrowed
view:

1. **Shared memory between processes** (`scratch(shared = true)` — anonymous
   pages that survive a fork). The value is the *sharing*, not the
   zero-copy read.
2. **Letting the OS page a huge file** rather than reading it whole — but
   only if the bytes are consumed through a handle, not a view.

Both are expressible as `fd: int`-style handles with explicit read/write
calls, which is `sys.fs`'s shape and adds nothing over it. So the honest
summary: **the module's remaining value is thin enough to question whether
it's worth having.**

## The apps that motivated it

`log-grep` (ripgrep-lite) and `mp3-player` both chose mmap specifically for
the zero-copy scan. Under this translation neither gets what it came for.
That's a genuine capability regression versus the Rust/Nim design, and it
traces to the same root as `core.slice`: **no borrowed views** is a
deliberate safety choice with a real performance cost in exactly the
scan-a-large-file case.

Worth naming plainly rather than burying: if large-file scanning is a
target workload, this is the place the Tier-1 model costs the most, and it
would be the strongest argument for some future read-only-view concept.

## Recommendation
Drop unless process-shared memory is wanted, in which case keep a minimal
`shared`-pages surface and drop the file-mapping half. Flagged, not
decided.
