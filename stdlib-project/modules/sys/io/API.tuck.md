# sys.io — Tuck translation

## Shape decision
Two `interface`s plus freeform `pending:` verbs, with a real error enum
carried by `[error: IoError]`. **Compiler-verified**, `./tuck ch`: `OK`,
6/6 `PENDING`.

This is the first module where Tuck's error model does *more* than the Nim
design's, rather than less.

## The API

```tuck
type IoError:
  | Ended
  | WouldBlock
  | Interrupted
  | Closed
  | Denied
  | Missing
  | AlreadyThere
  | Busy
  | TooBig
  | CrossDevice
  | TimedOut
  | Refused
  | Reset
  | Unreachable
  | Unsupported

type Anchor:
  | Start
  | Here
  | End

interface Streamable:
  fn readInto({self: Self, into: Seq[u8]}) -> {count: int} [io]
  fn write({self: Self, data: Seq[u8]}) -> {count: int} [io]

interface Seekable:
  fn position({self: Self}) -> i64 [io]
  fn seek({self: Self, offset: i64, from: Anchor}) -> i64 [io]

pending:
  fn read({s: Streamable, n: int}) -> !{data: Seq[u8]} [io, error: IoError]
  fn readExactly({s: Streamable, into: Seq[u8]}) -> !void [io, error: IoError]
  fn readAll({s: Streamable, limit: int}) -> !{data: Seq[u8]} [io, error: IoError]
  fn writeAll({s: Streamable, data: Seq[u8]}) -> !void [io, error: IoError]
  fn copyTo({src: Streamable, dst: Streamable, limit: i64}) -> !{count: i64} [io, error: IoError]
  fn flush({s: Streamable}) -> !void [io, error: IoError]
```

## Notes on the translation
- **`IoProblem` + `IoFailure` collapse into one enum.** The Nim design
  needed a `ref object of Failure` carrying a `problem` field so callers
  could branch without string matching. Tuck's `[error: IoError]` declares
  the possible variants *in the signature*, and `match r.err:` validates
  arms against them — a typo is a compile error naming the enum. So the
  wrapper type disappears and the guarantee gets stronger.
- **`worthRetrying` is dropped** as a derived helper: with the variants
  visible at the call site, `match` on `WouldBlock`/`Interrupted`/`TimedOut`
  is clearer than a boolean that hides which ones counted.
- **`Streamable`/`Seekable` stay two interfaces**, which was the Nim
  design's best call here — "a socket simply doesn't have it, and its
  signature says so." Explicit `satisfies` makes that stricter than Nim's
  structural concepts, and top-level `satisfies` means a type declared
  elsewhere can still be attached.
- **`readInto` keeps the buffer-filling shape** for the hot path, even
  though it can't mutate its argument in place under value semantics — the
  count is what's returned, and the filled buffer comes back with it. This
  is one place where the value-semantics translation is genuinely worse
  than the Nim original and worth revisiting if `Seq` gains a
  mutable-receiver form (see `FRICTIONS.md` #8).
- **`Buffered[S]` / `peek` / `skip` are not translated.** They need a
  wrapper that owns an inner stream plus a mutable buffer; expressible, but
  the design question is whether buffering belongs in the type or in the
  caller. Deferred rather than guessed.
- `View[byte]` → `Seq[u8]`, `Text` → `str`, per `core.slice`/`core.str`.

## Fits the real `std/*` precedent
`std/console.tuck` and `std/net.tuck` already declare `type IoError:` /
`type NetError:` enums and use `!{...}` returns with `[io, error: E]` — this
module is the generalization those two were already written against, not a
new convention.
