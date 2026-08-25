# std.compress — Tuck translation

## Shape decision
Freeform `pending:` verbs. **Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
type Method:
  | Gzip
  | Zlib
  | Deflate
  | Zstd

type Level:
  | Fastest
  | Balanced
  | Smallest

type CompressError:
  | Corrupt
  | Truncated
  | UnsupportedMethod

pending:
  fn pack({data: Seq[u8], how: Method, level: Level}) -> Seq[u8]
  fn unpack({data: Seq[u8], how: Method}) -> !Seq[u8] [io, error: CompressError]
  fn tryUnpack({data: Seq[u8], how: Method}) -> Seq[u8]?
```

## Notes
- **The Nim design's best call survives**: one `Packer`/`Unpacker` pair with
  the algorithm as an *argument*, not four near-identical types. "Switching
  a file from gzip to zstd is a one-word edit, not a type change."
- **`Deflate` stays exposed on purpose** — `std.archive`'s zip entries need
  the raw headerless stream, so hiding it inside gzip would break that.
- **The streaming form is not translated.** `newPacker(into: ByteSink)`
  wrapped a stream and wrote incrementally; without `TextSink`/`ByteSink`
  (see `core.fmt` — a callee cannot write through a parameter) the
  buffer-to-buffer form is what's left. That is a real capability loss for
  large files: `archive-cli` compressing a multi-gigabyte file must hold it
  in memory. **Worth solving via the `fd: int` handle convention** —
  `packTo({srcFd, dstFd, how})` — rather than leaving only the buffer form.
  Recorded, not designed.
- `zstdLevel` (the native -7..22 escape) and dictionary support are dropped
  from this sketch; both are named arguments in the Nim design and would
  return unchanged.
