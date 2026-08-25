# platform.watchdog — Tuck translation

## Shape decision
`actor`, per direct guidance — one watchdog peripheral per program is the
shape `platform.power`'s own `PowerDomain` precedent already assumes for
similar singleton hardware state.

**Compiler-verified**, `./tuck ch`: `OK`.

**A correctness-shaped version of the shared reply question, not just an
ergonomics one:** `feed` exists specifically to be called from the one
place in the program that has just proven the main loop is alive — the
Nim design's own doc comment says so directly ("the one call a correct
program makes from exactly the place that knows... a cycle completed").
Routing that call through an actor mailbox adds scheduling latency between
"the loop finished" and "the timer actually resets" — for most modules that
is an ergonomics question; for a watchdog, feeding late defeats the entire
mechanism. **Untouched by `TUCK-TRANSLATION.md`'s reply-pattern
resolution** — that resolution is about how a caller gets a *value* back;
`feed` never needed one, so it isn't a reply-shape problem at all. It's
purely about `send` latency itself, worth weighing heavier than everything
else here precisely because there's no small-message trick that fixes it.

## The API

```tuck
type ResetCause:
  | rcPowerOn
  | rcWatchdog
  | rcSoftware
  | rcBrownout
  | rcExternalPin
  | rcUnknown

actor Watchdog [queue: 4]:
  isRunning: bool = false
  timeoutMs: u32 = 0

  on configure({timeoutMs: u32}) -> void:
    timeoutMs = timeoutMs

  on start() -> void:
    isRunning = true

  on stop() -> void:
    isRunning = false

  on feed() -> void:
    return

  on select:
    | shutdown -> {}: isRunning = false
```

## In use

```tuck
Watchdog send configure {timeoutMs: 2000}
Watchdog send start {}
Watchdog send feed {}
```

## Open design questions
- **The `send`-latency problem, still fully open** — not the reply-pattern
  question (that's resolved), a different one: `feed` sends fine today, the
  concern is purely how long the message sits in the mailbox before the
  handler runs. No pattern in `TUCK-TRANSLATION.md` addresses this.
- `lastResetCause()` (a boot-time read, per the Nim design) isn't
  represented above at all — it's read once at startup from
  `platform.boot`'s reset path, before the scheduler and any actor exist,
  so it may not belong on this actor at all. Left unresolved rather than
  guessed at.
