# std.log — Tuck translation

## Shape decision
`interface LogSink` plus freeform `pending:` verbs. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type Level:
  | Trace
  | Debug
  | Info
  | Warn
  | Error

type Field:
  | FText({key: str, text: str})
  | FWhole({key: str, whole: i64})
  | FNumber({key: str, number: float})
  | FYes({key: str, yes: bool})
  | FSpan({key: str, ms: u64})

type Record = {atMs: u64, level: Level, msg: str, fields: Seq[Field]}

interface LogSink:
  fn emit({self: Self, r: Record}) -> void [io]
  fn accepts({self: Self, level: Level}) -> bool

pending:
  fn log({sink: LogSink, level: Level, msg: str, fields: Seq[Field]}) -> void [io]
  fn info({sink: LogSink, msg: str, fields: Seq[Field]}) -> void [io]
  fn warn({sink: LogSink, msg: str, fields: Seq[Field]}) -> void [io]
  fn fail({sink: LogSink, msg: str, fields: Seq[Field]}) -> void [io]
  fn newTextSink({minLevel: Level}) -> LogSink [io]
  fn newJsonSink({minLevel: Level}) -> LogSink [io]
```

## Notes on the translation
- **`FieldValue`'s variant record becomes a sum type**, which is the
  natural Tuck shape and gains exhaustive `match` for free — a sink that
  forgets a field kind is a compile error rather than a silent gap.
- **`error` could not be used as the verb name.** It's reserved (the
  `[error: E]` effect attribute), and the parse error says "expected
  function name" rather than naming the collision — recorded as
  `FRICTIONS.md` #5b. Using `fail`, which reads acceptably but is not what
  a logging API would choose.
- **`fSpan`/`fWhen` become plain `u64` milliseconds** rather than carrying
  `Duration`/`Instant`, pending `sys.time`'s `Instant`/`Timestamp` split
  (see that module's note — the distinct types exist, they're just not
  declared yet).
- **`fFailure` (a field carrying a `Failure`) is dropped.** Tuck errors are
  enum variants declared per-signature, not a heritable object — there's no
  single type a field could hold. A caller logs `$err` as text, or the
  variant name.
- **`fGroup` (nested fields) is dropped for now** — it needs `Field` to
  recurse through `Seq[Field]`, which *does* work (verified in the JSON
  tree probe), so this is a "not yet written" rather than a blocker.
- **`Log` as an object is dropped**; the sink is passed directly. The Nim
  design's own note said `Log` is `Messenger`-shaped but has no `receive`
  ("nothing ever reads a record back out"), so the object was carrying one
  verb — free functions say it with less.

## Still true after translation
The Nim pass's rename of `Handler` → `LogSink` holds: "a sink is where
things go; 'Handler' says nothing about direction." And `accepts(level)`
before building fields remains the right shape, since building a
`Seq[Field]` allocates — more so here than in Nim, per the tier's
allocation ruling.
