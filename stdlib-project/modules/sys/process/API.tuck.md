# sys.process — Tuck translation

## Shape decision
Freeform `pending:` verbs over a `pid: int` handle, matching `sys.fs`'s
`fd: int` and `std/net.tuck`'s socket handles. **Compiler-verified**,
`./tuck ch`: `OK`.

## The API

```tuck
type ProcError:
  | NotFound
  | Denied
  | SpawnFailed

type Wiring:
  | Inherit
  | Discard
  | Capture

type ExitStatus:
  | Exited({code: i32})
  | Signaled({sig: Signal})

pending:
  fn spawn({program: str, args: Seq[str], stdin: Wiring, stdout: Wiring, stderr: Wiring}) -> !{pid: int} [io, error: ProcError]
  fn wait({pid: int}) -> !ExitStatus [io, error: ProcError]
  fn tryWait({pid: int}) -> ExitStatus? [io]
  fn signalTo({pid: int, sig: Signal}) -> !void [io, error: ProcError]
  fn isRunning({pid: int}) -> bool [io]
  fn stdinFd({pid: int}) -> {fd: int}? [io]
  fn stdoutFd({pid: int}) -> {fd: int}? [io]
  fn stderrFd({pid: int}) -> {fd: int}? [io]
```

## Notes
- **`ExitStatus` as a sum type is the whole point of this module**, and it
  translates perfectly. Round-1's finding was that an opaque struct with
  independently-nullable `code()`/`signal()` accessors is the classic POSIX
  `wait()` footgun a supervisor can't safely paper over. Tuck's
  `| Exited({code: i32}) | Signaled({sig: Signal})` plus **exhaustive
  `match`** makes forgetting a case a compile error — stronger than the
  Nim design, which relied on the author choosing to match.
- **The `Command` builder collapses into one `spawn` call** with named
  arguments. The Nim design already noted this ("the builder existed to
  express combinations nobody uses"); Tuck's trailing-named-argument
  convention makes it natural.
- **Pipes are `fd: int`, not a `Pipe` type** — same handle convention as
  `sys.fs`, and they plug into `sys.io`'s `Streamable` via top-level
  `satisfies` rather than being a distinct type.
- **`Child` as a `Lifecycle`/`Waitable` object is dropped.** With a `pid`
  handle the verbs are free functions; `wait`/`isRunning`/`signalTo` say
  the same thing without a receiver object that holds nothing but the pid.
- `Signal` is shared with `sys.signal` rather than duplicated — the Nim
  design's round-1 note ("reusing `sys.signal`'s `Signal` type rather than
  inventing a parallel one") still applies.

## Still the least-validated module in the corpus
`INDEX.md` flagged that `sys.process` had **zero** validating apps before
round 1 added `process-supervisor`. Nothing about the Tuck translation
changes that — the design is grounded in the survey's `Command` pattern
plus one app, so surprises are likelier here than in modules with several
independent consumers.
