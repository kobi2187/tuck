# std.archive — Nim API

## Purpose
Zip and tar files: list what's inside, pull one entry out, put one entry in — streaming both ways, so a 10 GB archive never needs 10 GB of memory. Compression comes from `std.compress`; there is no second deflate in here.

## Protocols implemented
`ZipReader` is `Resource`, `Collection[Entry]` and `Gettable[TextView, Entry]`. `ZipWriter`, `TarReader` and `TarWriter` are `Resource`; `TarReader` is also a `Collection[Entry]`. Opening one entry is the vocabulary's `open(target, locator)` and closing it is `close` — the same two words as a file.

## The API

```nim
type
  Entry* = object
    name*: Text
    size*, packedSize*: uint64
    modified*: Instant
    mode*: Permissions
    encrypted*: bool
    kind*: EntryKind          ## File | Folder | LinkTo(target)
  ZipReader* = object         ## needs a seekable source: the index lives at the end
  ZipWriter* = object
  TarReader* = object         ## needs nothing seekable: tar is a plain linear stream
  TarWriter* = object

proc openZip*(source: var SeekableSource): ZipReader   ## raises `Failure` on a bad index
proc tryOpenZip*(source: var SeekableSource): Option[ZipReader]
iterator list*(z: ZipReader): Entry                    ## the Collection primitive
proc get*(z: ZipReader; name: TextView): Option[Entry]  ## Gettable — metadata, no decompression
proc open*(z: var ZipReader; name: TextView;
           password = none(SecretText)): ByteSource
  ## The `open(target, locator, options)` shape. Raises if the entry is missing or
  ## the password is wrong; `tryOpen` hands back `none` instead.
proc close*(z: var ZipReader)

proc newZipWriter*(into: var ByteSink): ZipWriter
proc open*(z: var ZipWriter; name: TextView;
           level = Balanced; modified = now(); mode = defaultMode();
           password = none(SecretText)): ByteSink
  ## Returns the sink for this entry's contents. Close it before opening the next.
proc close*(z: var ZipWriter)                          ## writes the central directory

proc newTarReader*(source: var ByteSource): TarReader
iterator list*(t: var TarReader): Entry                ## advances; read the body between yields
proc read*(t: var TarReader; n: int): List[byte]       ## the current entry's bytes
proc newTarWriter*(into: var ByteSink): TarWriter
proc open*(t: var TarWriter; entry: Entry): ByteSink
proc close*(t: var TarWriter)

proc openTarGz*(path: Path): TarReader
proc createTarGz*(path: Path; level = Balanced): TarWriter
  ## Literally `newTarWriter(newPacker(file, how = Gzip, level))`. Named because
  ## ".tar.gz" is the single most common archive on earth and "compose it yourself"
  ## was one generic parameter of ceremony too many.

proc verify*(path: Path): ArchiveReport
type ArchiveReport* = object
  checked*: Count
  damaged*: List[Text]        ## entry names that failed their checksum
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `zip::Reader::open_entry(name)` | `open(z, name)` | The vocabulary's resource verb, with the entry name as the locator. Symmetric with the writer, and symmetric with `sys.fs`. |
| `open_entry_encrypted(name, pw)` | `open(z, name, password =)` | One method, options last — see Vocabulary exceptions for why merging is safe here. |
| `create_entry(name, opts)` | `open(w, name, level =, mode =, ...)` | `EntryOptions` as a struct becomes four named arguments; `create` and `open` were two words for acquiring a handle. |
| `Writer::finish()` | `close` | The vocabulary's release verb. Writing the central directory is what closing a zip *means*. |
| `entries()` | `iterator list` | The Collection primitive, so `count`, `first`, `keepIf` and `each` all arrive without being redeclared. |
| `EntryInfo` | `Entry` | "Info" adds nothing; the type is already only metadata. |
| `EntryKind::Symlink{target}` | `LinkTo(target)` | Reads as what it is at a glance. |
| `VerifyReport::corrupt_entries` | `ArchiveReport.damaged` | Plain word, and it pairs with `checked` in a sentence: "checked 412, damaged 0." |

## In use

```nim
# archive-cli: create, streaming, one progress line per file
var zip = newZipWriter(outFile)
for path in inputs.walk():
  var entry = zip.open(path.relative, level = opts.level, password = opts.password)
  copyInto(path.openRead(), entry, onProgress = bars.open(total = path.size).set)
  entry.close()
zip.close()

# archive-cli: `archive list` is one line, because ZipReader is a Collection
for e in openZip(archive).list():
  echo e.name, "  ", e.size, if e.encrypted: "  [locked]" else: ""

# archive-cli: `archive test` reuses the real extraction path, into a discard sink
let report = verify(archive)
if report.damaged.count > 0: fail("damaged: " & report.damaged.toText())
```

## Vocabulary exceptions
`verify` is a domain verb, shared deliberately with `std.crypto`'s signature check — in both places it means "read the whole thing and tell me whether it holds together", which is one concept, not two.

**Zip and tar are not unified behind one type, on purpose.** A zip reader needs a seekable source because its index sits at the end of the file; a tar reader needs nothing of the kind. A shared "container" concept would force tar to pretend it can seek or zip to pretend it can stream, and the honest asymmetry is visible right there in the two constructors' parameter types. `openTarGz` and `createTarGz` bridge the common case without hiding it.

**Encryption is a named argument, not a second method.** The Rust design split `open_entry` from `open_entry_encrypted` so nobody could silently produce a legacy ZipCrypto entry. That risk does not exist here: this implementation contains no ZipCrypto code at all, only `std.crypto`'s `seal`/`unseal`, so `password = some(pw)` selects the only encryption path that exists. Merging removes a name without reopening the hole it was guarding. `Entry.encrypted` still reports the truth on read, so a caller can never mistake a locked entry for a plain one.
