# std.testing — Tuck translation

## Shape decision
Freeform `pending:` verbs plus result records. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type Outcome:
  | Passed
  | Failed
  | Skipped

type Result = {name: str, outcome: Outcome, message: str, elapsedMs: u64}
type Report = {results: Seq[Result], passed: int, failed: int, skipped: int}

type TestError:
  | Aborted

pending:
  fn check({ok: bool, what: str}) -> void [io]
  fn require({ok: bool, what: str}) -> !void [io, error: TestError]
  fn expectEq[T]({got: T, want: T, what: str}) -> void [io]
  fn note({msg: str}) -> void [io]
  fn skip({why: str}) -> void [io]
  fn runSuite({pattern: str}) -> Report [io]
  fn runBenchmarks({pattern: str}) -> Report [io]
  fn runFuzz({target: str, forMs: u64}) -> Report [io]
  fn drawByte({seed: u64}) -> {seed: u64, value: u8}
  fn drawBytes({seed: u64, count: int}) -> {seed: u64, bytes: Seq[u8]}
  fn killSubprocess({pid: int}) -> void [io]
```

## The big loss: `check` cannot see its own expression

The Nim design's single best feature here was:

> `check a.len == b.len` prints both sides without you naming them — the
> failure message is built from the *expression tree*.

That works because `check` is a **template** and Nim templates receive
unevaluated AST. Tuck has no user-facing macro or template facility
verified in this pass, so `check` receives a plain `bool` — by the time it
runs, `a.len == b.len` has collapsed to `false` and the operands are gone.
Hence the `what: str` parameter: the caller has to describe the assertion
themselves.

**This is a genuine ergonomic regression** and worth flagging as a
macro-system motivation. Tuck's *own* test harness (`tests/harness.nim`)
solves it by being written in Nim — which is available to the compiler's
tests but not to a Tuck user testing Tuck code.

Note `std.serde-derive`'s Nim translation called macros "the one place the
Nim version is plainly better than the Rust original" — the same facility
would fix both.

## Notes
- **`suite`/`test` as block-structuring templates are dropped**, same
  reason. Tests become ordinary `fn`s discovered by name pattern
  (`runSuite {pattern: "..."}`), which is closer to Go's convention than
  Nim's — and Go manages fine without macros.
- **The `Draw` fuzz source becomes explicit seed-passing**
  (`drawByte`/`drawBytes` returning the advanced seed), same value-semantics
  pattern as `std.random`'s `Dice`, and with the same open question about
  whether an `object` with `self` mutation reads better.
- **`fault::kill_subprocess` survives as `killSubprocess`.** Round-1 added
  fault injection because `kv-store-server`'s core claim ("no lost or
  corrupted acknowledged writes after a crash") is untestable without it.
  That reasoning is unchanged.
- **`cleanup` (LIFO, runs even after a raise) is not translated** — it
  needs either a defer mechanism or a callback registry; the `fnsig`+`bake`
  route works for the callback half but there's no scope-exit hook to run
  it. Same gap `core.mem::Scrubbed` hit.
- **`tempFolder` survives** and is worth keeping — a test that has to clean
  up its own directory usually doesn't.
