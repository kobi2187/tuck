# sys.io — Nim API

## Purpose
One shape for anything that moves bytes. A file, a socket, a child process's pipe, a memory mapping and an in-memory `Text` all answer the same two words, so `copy`, `lines`, `readAll` and every codec in `std` are written exactly once and work on all of them with no adapter in between.

## Protocols implemented
This module *is* `Streamable` — PROTOCOLS names it, `sys.io` gives it a body and the derived bundle every stream inherits. `Buffered[S]` is additionally `Resource`.

## The API

```nim
type
  IoProblem* = enum
    ## The one categorised answer to "why did that fail?", library-wide.
    Ended, WouldBlock, Interrupted, Closed, Denied, Missing, AlreadyThere,
    Busy, TooBig, CrossDevice, TimedOut, Refused, Reset, Unreachable, Unsupported
  IoFailure* = ref object of Failure
    problem*: IoProblem     ## `worthRetrying` is derived from this — no string matching

  Streamable* = concept s, var s
    ## Implement these two. Everything below is written once, for every stream there is.
    readInto(s, var openArray[byte]) is int   ## bytes placed; 0 means the stream ended
    write(s, openArray[byte]) is int          ## bytes taken; may be fewer than offered

  Seekable* = concept s, var s
    ## Separate on purpose: a socket simply doesn't have it, and its signature says so.
    s.position is int64
    seek(s, int64, Anchor) is int64
  Anchor* = enum Start, Here, End

proc read*(s: var Streamable; n: int): seq[byte]
  ## The friendly form. Allocates; use `readInto` on a hot path.
proc tryRead*(s: var Streamable; n: int): Option[seq[byte]]
proc readExactly*(s: var Streamable; into: var openArray[byte])
  ## Fills `into` completely or raises `IoFailure(problem: Ended)`. No short-read surprises.
proc readAll*(s: var Streamable; limit = 64 * MiB): seq[byte]
  ## `limit` is mandatory-by-default so an untrusted socket can't eat your memory.
proc writeAll*(s: var Streamable; data: openArray[byte])
  ## Loops until every byte is gone. `write` alone may take fewer — that's real socket behaviour.
proc copy*(src: var Streamable; dst: var Streamable; limit = Unlimited): int64 {.discardable.}
  ## Returns bytes moved, so a progress bar has something to show.
proc flush*(s: var Streamable)              ## no-op unless the stream buffers
iterator lines*(s: var Streamable): TextView  ## borrowed, one buffer reused, nothing allocated per line

proc first*[S](s: sink S; n: int64): Limited[S]      ## cap a stream at n bytes
proc followedBy*[A, B](a: sink A; b: sink B): Joined[A, B]
  ## Same two words `core.iter` uses for the same two ideas.

type Buffered*[S] = object   ## Resource: `close` flushes then closes the inner stream
proc buffered*[S](inner: sink S; capacity = 64 * KiB; memory = defaultMemory()): Buffered[S]
proc peek*[S](b: var Buffered[S]): View[byte]   ## look at what's ready without consuming it
proc skip*[S](b: var Buffered[S]; n: int)       ## consume what `peek` showed you

var stdIn*, stdOut*, stdErr*: Console   ## Streamable, and `stdErr` is unbuffered
```

## Friendly-naming notes

| Rust/Go name | Nim name | Why |
|---|---|---|
| `Reader` + `Writer` traits | one `Streamable` | PROTOCOLS collapses the pair. One word to learn, and `copy` needs no bound-juggling |
| `read(&mut buf) -> usize` | `readInto(s, buf)` | says where the bytes land; frees `read` for the everyday allocating form |
| `read_exact` | `readExactly` | spelled out; the adverb is the whole difference |
| `write_all` | `writeAll` | plural of `write`, exactly as `addAll` is of `add` |
| `fill_buf` / `consume(n)` | `peek` / `skip(n)` | two words anyone already knows |
| `BufReader` / `BufWriter` | one `Buffered[S]` | direction is already in the inner stream; two types were one too many |
| `Take` / `Chain` | `first(n)` / `followedBy` | the names `core.iter` already uses for cap-and-concatenate |
| `SeekFrom::{Start,Current,End}` | `Anchor.{Start, Here, End}` | `Here` beats `Current` at a call site |
| `ErrorKind` *(open question)* | `IoProblem` | resolved: one enum for the whole library, so `worthRetrying` is a lookup |

## In use

```nim
# web-downloader: body -> partial file, with a progress bar and a resumable tail
var body = response.stream()
var partial = open(dest & ".part", Appending)
let got = copy(body, partial)             # same `copy` archive-cli uses, unmodified
partial.persist(metadata = false)

# process-supervisor: a child's stdout into a rotating log, zero glue
var log = RotatingLog(dir: "/var/log/app", maxBytes: 10 * MiB)   # just a Streamable
copy(child.output.get(), log)
```

## Vocabulary exceptions
- **`readInto` is the primitive, not PROTOCOLS' literal `read(x, n): seq[byte]`.** Keeping the allocating form as the primitive would put a heap allocation inside every socket read. `read(n)` survives as the derived convenience, written once here, so PROTOCOLS' signature is still true of every `Streamable` — it just isn't what an implementer writes.
- **`Seekable` is a plain concept, not a tenth protocol.** It exists so a signature can say "this one can jump around"; `sys.fs`'s `File` and `sys.mmap`'s `Mapping` have it, `sys.net`'s `TcpStream` never will.
- **`flush` is a domain verb** — pushing buffered bytes onward has no structural analogue, and it is deliberately *not* `persist` (that word means durability on disk, and lives in `sys.fs`).
