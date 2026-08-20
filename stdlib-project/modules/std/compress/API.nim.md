# std.compress — Nim API

## Purpose
Make bytes smaller on their way somewhere, or bigger on their way back. One packer, one unpacker, and the algorithm is an argument — gzip, zlib, raw deflate or zstd — wrapping any stream, file, socket or buffer.

## Protocols implemented
`Packer` is `Streamable` (write half) and `Resource`; `Unpacker` is `Streamable` (read half) and `Resource`. That is the whole module: compression is a stream transform, so the stream protocols say everything.

## The API

```nim
type
  Method* = enum Gzip, Zlib, Deflate, Zstd
    ## `Deflate` is the raw headerless stream. It is exposed on purpose, not hidden
    ## inside gzip, because `std.archive`'s zip entries need exactly that and must
    ## not carry a private second copy of it.
  Level* = enum Store, Fast, Balanced, Smallest
  Packer* = object
  Unpacker* = object
  Info* = object            ## gzip's optional header, when there is one
    name*: Option[Text]
    modified*: Option[Instant]

proc newPacker*(into: var ByteSink; how = Gzip; level = Balanced;
                zstdLevel = 0; dictionary: View[byte] = @[]): Packer
  ## Options last. `zstdLevel` reaches zstd's native -7..22 when the four-word
  ## `Level` isn't precise enough; `dictionary` is zstd's shared-dictionary mode
  ## for many small payloads. Both are ignored by the other three methods.
proc write*(p: var Packer; data: View[byte]): int      ## Streamable
proc close*(p: var Packer)
  ## Flushes the trailer and checksum. **Must be called** — see the Nim note below.
proc tryClose*(p: var Packer): bool
proc isOpen*(p: Packer): bool
proc unwrap*(p: sink Packer): ByteSink                 ## take the inner sink back

proc newUnpacker*(source: var ByteSource; how = Gzip): Unpacker
  ## Validates the header eagerly, so a wrong `how` fails here, not 4 MB later.
proc read*(u: var Unpacker; n: int): List[byte]        ## Streamable
proc close*(u: var Unpacker)
proc isOpen*(u: Unpacker): bool
func info*(u: Unpacker): Option[Info]

proc pack*(data: View[byte]; how = Gzip; level = Balanced): List[byte]
proc unpack*(data: View[byte]; how = Gzip): List[byte]
proc tryUnpack*(data: View[byte]; how = Gzip): Option[List[byte]]
  ## The one-shot pair, for buffers small enough to hold twice. Built on the
  ## streaming types above, not a second implementation.
```

**Nim note — why `close` stays explicit.** Nim's `=destroy` hook is `{.raises: [].}`: a destructor cannot raise. A compressor's final flush *can* fail (full disk, closed socket), so a drop-based cleanup would have no way to tell you. `close` is therefore a real call you make, and `=destroy` only releases the internal window buffer. This is a Nim constraint that happens to land on the same answer the Rust design chose deliberately — the reasoning is now enforced by the language rather than by discipline.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `gzip::Reader` / `zlib::Reader` / `zstd::Reader` | `Unpacker` + `how = ` | Four near-identical types collapse into one plus an enum. Switching a file from gzip to zstd is now a one-word edit, not a type change. |
| `Writer` | `Packer` | Pairs audibly with `Unpacker`; `Writer` collides with every other writer in the library. |
| `Level::Default` / `Best` | `Balanced` / `Smallest` | Says what you get. "Best" begs the question "best at what?" |
| `Writer::finish() -> W` | `close` + `unwrap` | `close` is the vocabulary's release verb and is idempotent; `unwrap` separately hands back the inner sink for the callers who want it. |
| `with_level` / `with_dict` | named arguments | Two constructor variants become two options-last arguments on the one constructor. |
| `gzip_compress(data, level)` | `pack(data, how =, level =)` | One convenience pair for every method instead of six near-duplicates. |
| `Header` | `Info` | It is metadata about the stream, not a byte layout. |

## In use

```nim
# archive-cli: the same Packer, composed two different ways
var entry = newPacker(zip.open("notes.txt"), how = Deflate, level = opts.level)
entry.write(fileBytes); entry.close()                # per-entry, raw deflate

var whole = newPacker(outFile, how = Gzip, level = Smallest)
var tar = newTarWriter(whole)                        # tar.gz: compress the container once
```

```nim
# log-grep: a rotated .log.gz scans exactly like a plain file
var lines = newUnpacker(rotated, how = Gzip)
for line in lines.asText().split('\n'):
  if line.has(rx): report(line)
```

```nim
# web-downloader: Content-Encoding: gzip, decompressed off a live socket
var body = if resp.headers.get("content-encoding") == some("gzip"):
             newUnpacker(resp.body, how = Gzip) else: resp.body
copyInto(body, partFile)
```

## Vocabulary exceptions
`pack` and `unpack` are domain verbs; the structural table has no word for "same bytes, fewer of them". They take their data first and their options last, so the shape is guessable even the first time you meet them.

`unwrap` is a second release verb sitting alongside `close`, which looks like a synonym and isn't: `close` finishes the compressed stream (mandatory, may raise), while `unwrap` hands back the thing you wrapped (optional, cannot fail). Merging them would have forced `close` to return a value that nine callers in ten discard — and `{.discardable.}` on a value that expensive to ignore is exactly the sort of quiet footgun the vocabulary exists to remove.

**Brotli is not here.** It is genuinely common in HTTP `Content-Encoding`, and leaving it out is a scope decision carried forward rather than an oversight: adding a fifth `Method` costs one enum case, so the door is open if a validating app ever needs it.
