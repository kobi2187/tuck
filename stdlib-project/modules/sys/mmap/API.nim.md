# sys.mmap — Nim API

## Purpose
Ask the OS to make a file's bytes simply *be there*, at an address, instead of reading them in chunks. What you get back is an ordinary `View[byte]`, so every `core.iter` adapter and every `std.regex` matcher works on it with no wrapper and no copy.

## Protocols implemented
`Mapping` and `WritableMapping` are `Resource` (`open`/`close`/`isOpen`) and `Streamable` + `Seekable` via a cursor, so a mapping can also be handed to anything that takes a stream.

## The API

```nim
type
  Mapping* = object          ## read-only. Resource
  WritableMapping* = object  ## read-write. A different type, so a signature says which
  AccessPattern* = enum Normal, Sequential, Random, WillNeed, DoneWith
const WholeFile* = -1

proc map*(f: File; at = 0'i64; length = WholeFile): Mapping
  ## Read-only. `at`/`length` map a window: seeking into a 400 MB FLAC and mapping the
  ## 2 MB you need beats paging in the whole file for one seek.
proc tryMap*(f: File; at = 0'i64; length = WholeFile): Option[Mapping]
proc mapWritable*(f: File; at = 0'i64; length = WholeFile): WritableMapping
  ## Deliberately a longer, greppable name — changing a file through a pointer deserves
  ## to be visible when someone reads the diff.
proc scratch*(bytes: int; shared = false): WritableMapping
  ## Anonymous pages, no file behind them. `shared = true` survives a fork.

proc view*(m: Mapping): View[byte]              ## zero copy, and the whole point of the module
proc edit*(m: var WritableMapping): var openArray[byte]
proc count*(m: Mapping): int                    ## bytes mapped
proc close*(m: var Mapping)                     ## idempotent; also runs from `=destroy`
proc isOpen*(m: Mapping): bool

proc expect*(m: Mapping; pattern: AccessPattern)
  ## Tell the kernel how you're about to read this. `Sequential` doubles readahead for a
  ## start-to-end scan; `Random` turns it off. Only the caller knows which, so only the
  ## caller says so — this module never guesses.
proc persist*(m: WritableMapping; wait = true)
  ## Same word `sys.fs`'s `File` uses, for the same promise: these bytes are on the disk now.
proc freeze*(m: sink WritableMapping): Mapping  ## drop write permission; no remap, no copy
```

**The hazard this module does not pretend to solve.** If another process truncates or replaces a file you have mapped, touching the vanished pages raises `SIGBUS` on POSIX — an OS-level fault that no portable API can turn into an ordinary `Failure` without paying for a check on every single byte access, which would defeat the reason you mapped it. Map files you control, or coordinate with whoever else writes them. Stated plainly here rather than quietly promised away.

**Nim notes.** `View[byte]` is `core.slice`'s borrowed view, and Nim's `--mm:arc` destructor hooks unmap the region when the `Mapping` leaves scope — no `defer`, no manual `munmap`, and a `view()` cannot outlive its `Mapping` because the view borrows it. On a 32-bit target `map` of a large file raises `TooBig` rather than mapping a truncated window.

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `Mmap` / `MmapMut` | `Mapping` / `WritableMapping` | "mmap" is the syscall; a mapping is the thing you have. The distinction stays at the type level, as designed |
| `Mmap::open(file)` / `open_range` | `map(f, at =, length =)` | one proc, two trailing named arguments, and the window case stops being a second name |
| `map_anon(len)` | `scratch(bytes)` | says what it's for. Nobody maps anonymous pages except as scratch space |
| `as_slice` / `as_mut_slice` | `view` / `edit` | two short words; `view` matches `core.slice`'s `View[T]` exactly |
| `advise(Advice::Sequential)` | `expect(m, Sequential)` | `madvise` reads as an instruction to the caller; `expect` is the caller telling the kernel |
| `Advice::DontNeed` | `DoneWith` | plain English for "you can drop these pages" |
| `flush` / `flush_async` | `persist(m, wait =)` | one verb, shared with `sys.fs`, and the async case is a named argument |
| `make_read_only` | `freeze` | one word, and it's the word people already use for this |

## In use

```nim
# log-grep: map, hint, scan. No read loop, no chunk-boundary bookkeeping, no copy.
var f = open(path, Reading)
var m = f.map()
m.expect(Sequential)
for line in m.view().splitOn('\n'):          # core.iter, straight over the mapped bytes
  if pattern.matches(line): results.send(Hit(file: path, text: line))

# mp3-player: seek into a big file, map only the window the decoder is about to eat
var window = track.map(at = frameOffset, length = 2 * MiB)
decoder.feed(window.view())

# backup-sync: build a block-signature table without ever allocating a read buffer
for block in m.view().chunks(BlockSize):
  signatures.add(rollingChecksum(block))
```

## Vocabulary exceptions
- **`map`, `expect` and `freeze` are domain verbs.** `open` is `Resource`'s (a `Mapping` re-opens itself with it); "make these file bytes appear at an address" is a distinct act that deserves its own word.
- **`view`/`edit` are not `get`/`set`.** They return the whole region, not one item at a locator. Per-byte access is `View[byte]`'s job — `m.view().get(i)` is `Gettable`, defined once in `core.slice` and not restated here.
- **`persist` is reused from `sys.fs` on purpose.** `msync` and `fdatasync` make the same promise about the same file; giving them two names would be exactly the synonym the maintainability contract forbids.
