# sys.env — Tuck translation

## Shape decision
Freeform `pending:` verbs, extending the real `std/sys.tuck` (which already
has `argCount`/`argAt`/`getEnv`/`exit` in exactly this shape).
**Compiler-verified**, `./tuck ch`: `OK`.

## The API

```tuck
pending:
  fn getEnv({name: str}) -> {value: str}? [io]
  fn setEnv({name: str, value: str}) -> void [io]
  fn removeEnv({name: str}) -> void [io]
  fn hasEnv({name: str}) -> bool [io]
  fn envNames() -> {names: Seq[str]} [io]
  fn argCount() -> {count: int} [io]
  fn argAt({index: int}) -> {arg: str} [io]
  fn programName() -> {name: str} [io]
  fn workingDir() -> {path: str} [io]
  fn setWorkingDir({path: str}) -> void [io]
  fn exePath() -> {path: str}? [io]
  fn tempDir() -> {path: str} [io]
  fn exit({code: int}) -> void [io]
```

## Notes
- **The `Environment` object disappears.** The Nim design had a singleton
  `let env*: Environment` so the verbs could hang off it as
  `get`/`set`/`has`/`list`. There is exactly one process environment, so
  the object carried no state — it existed to give the protocol verbs a
  receiver. Free functions say the same thing with less, and match
  `std/sys.tuck`'s existing `getEnv`/`argAt` spelling.
- **`get`/`set` become `getEnv`/`setEnv`** for the same reason `core.hash`
  needed `feedFast`/`feedSafe`: free functions can't overload
  (`[TK-TY02]`), and `get`/`set`/`has` are wanted by many modules. The
  suffix is the cost of a flat namespace.
- **The UTF-8 distinction is dropped.** Nim's design split
  `get` (raises on invalid UTF-8) from `getBytes` (never fails), because
  absence and corruption are different. Tuck's `str` doesn't expose that
  distinction, and no validated app needed it — recorded rather than
  silently lost.
- **`snapshot` into a `Table` is not translated** — it depends on
  `alloc.map`, which is blocked on the key-hashing question. Its *reason*
  is worth preserving though: POSIX `setenv`/`getenv` aren't safe to call
  concurrently, so reading the environment once at startup sidesteps the
  problem rather than documenting it. Tuck's cooperative single-threaded
  scheduler makes this less urgent than it was for Nim, but `sys.thread`
  reintroduces it.
- **`arguments()` iterator → `argCount`/`argAt`.** Matches `std/sys.tuck`
  exactly; a `Seq[str]` form would be nicer to use and is worth considering
  once the allocation question settles.
