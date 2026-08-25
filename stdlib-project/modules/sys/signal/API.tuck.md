# sys.signal — Tuck translation

## Shape decision
Freeform `pending:` verbs. **Compiler-verified** alongside `sys.process`
(they share the `Signal` enum), `./tuck ch`: `OK`.

## The API

```tuck
type Signal:
  | SigInt
  | SigTerm
  | SigHup
  | SigQuit
  | SigUsr1
  | SigUsr2

pending:
  fn onSignal({sig: Signal}) -> void [io]      ## start delivering this one
  fn nextSignal({timeoutMs: u32}) -> Signal? [io]
```

## The design decision that survives translation intact

Round-0's finding #3 was that **`sys.signal` cannot be a handler-callback
API**: `web-downloader`'s requirement (Ctrl-C must leave a resumable
partial file, never a corrupt one) rules out calling into `sys.fs` from
real OS signal-handler context, which is unsafe by construction on every
OS. The module resolved to a receive/poll model instead.

That reasoning is unchanged in Tuck, and the language reinforces it:
a signal handler would have to be a `{.nimcall.}` non-capturing function
that cannot raise — the same constraint `platform.interrupt`'s ISRs carry —
so a callback API would be even more restricted here than it was in Nim.
`nextSignal` returning `Signal?` is the right shape.

## Notes
- **`nextSignal` rather than `receive`.** Same reasoning as `sys.fs`'s
  watcher: nothing is ever *sent* to the signal source, so borrowing
  `Messenger`'s verb was always a stretch. With no protocol machinery to
  satisfy in Tuck, the plain name wins.
- **How this composes with `std.async` is already settled** by round-3's
  ruling, and it survives: Ctrl-C *detection* stays this module's job
  (cheap, task-count-independent), while "stop accepting work, drain
  in-flight, print a partial report" is entirely `std.async`'s scope
  responsibility. In Tuck that reads as `nextSignal` in a small polling
  task that calls `rootScope().stop()`.
- **`SigKill`/`SigStop` are deliberately absent** — they cannot be caught,
  so offering them in a *delivery* API would be a lie. (`sys.process`'s
  `signalTo` is a different question: sending them is legal.)
