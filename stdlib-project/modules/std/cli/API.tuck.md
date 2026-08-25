# std.cli — Tuck translation

## Shape decision
Freeform `pending:` over declarative records. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type ArgKind:
  | AFlag
  | AText
  | ANumber

type ArgSpec = {name: str, short: str, kind: ArgKind, help: str, required: bool}
type Command = {name: str, help: str, args: Seq[ArgSpec], subcommands: Seq[Command]}
type Args = {values: Seq[{key: str, value: str}], positional: Seq[str]}

type Colour:
  | Plain
  | Red
  | Green
  | Yellow
  | Blue

type CliError:
  | BadUsage
  | UnknownFlag
  | MissingValue

pending:
  fn parse({c: Command, argv: Seq[str]}) -> !Args [io, error: CliError]
  fn tryParse({c: Command, argv: Seq[str]}) -> Args?
  fn textOf({a: Args, name: str}) -> str?
  fn numberOf({a: Args, name: str}) -> i64?
  fn hasFlag({a: Args, name: str}) -> bool
  fn usageOf({c: Command}) -> str

  fn newProgress({total: int, label: str}) -> {id: int} [io]
  fn advance({id: int, delta: int}) -> void [io]
  fn setProgress({id: int, done: int}) -> void [io]
  fn finishProgress({id: int}) -> void [io]

  fn renderTable({headers: Seq[str], rows: Seq[Seq[str]]}) -> str
  fn ask({question: str, fallback: str}) -> str [io]
  fn askSecret({question: str}) -> str [io]
  fn confirm({question: str, fallback: bool}) -> bool [io]
  fn styled({text: str, colour: Colour, bold: bool}) -> str
  fn isTerminal() -> bool [io]
```

## Notes on the translation
- **`Command` is a plain nested record** — `subcommands: Seq[Command]` is
  the recursion-through-`Seq` shape that works (verified in the JSON probe).
  So the whole command tree is declarative data, which is nicer than the
  Nim design's `command` macro and needs no macro facility.
- **`Command` recursing into itself is the module's best structural fit**,
  and it means `usageOf` is an ordinary recursive function over data.
- **`isTerminal` is added**, closing the round-4 gap: the Nim design's own
  purpose line said the module "knows when not to colour," implying an
  internal TTY check, but exposed no predicate for a caller's own
  decisions ("only show the progress bar if interactive").
- **`Progress` becomes an `{id: int}` handle**, not an object — same handle
  convention as `sys.fs`/`sys.process`, and it sidesteps the mutation
  problem (a progress bar is inherently stateful; the state lives in the
  runtime, not in a value the caller must re-bind).
- **`Table` renamed to `renderTable`** returning `str`. The Nim design
  deliberately collided its `Table` with `alloc.Table` and resolved it by
  qualified import; with a flat namespace and no overloading, a distinct
  verb is simpler and `show(t) -> Text` was already the shape.
- **`ProgressGroup` (many bars, one per worker) is dropped** — it exists for
  concurrent workers, and with a single-threaded scheduler the multi-bar
  case is `image-thumbnailer`'s async tasks rather than threads. Worth
  restoring if that app is revisited.
- **`askSecret` returning plain `str` is a real weakening.** The Nim design
  returned `Secret[Text]` so a passphrase couldn't be `echo`ed by accident
  — that depended on `alloc.allocator`'s `Secret[T]`, which has no Tuck
  counterpart (see `core.mem`'s scrubbing gap). Noted rather than hidden.
