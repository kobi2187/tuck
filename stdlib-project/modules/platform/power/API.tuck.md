# platform.power — Tuck translation

## Shape decision
Freeform `pending:` over sum types. **Compiler-verified**, `./tuck ch`: `OK`.

```tuck
type SleepDepth:
  | Light
  | Deep
  | Coldest

type WakeKind:
  | ByTimer
  | ByGpio
  | ByRtc
  | ByBusTraffic
  | ColdStart

type WakeSource = {kind: WakeKind, pin: int, afterMs: u32}
type WakeReason = {kind: WakeKind, pin: int}

pending:
  fn enterSleep({depth: SleepDepth, sources: Seq[WakeSource]}) -> WakeReason
  fn deepestFor({sources: Seq[WakeSource]}) -> SleepDepth
  fn lastWakeReason() -> WakeReason?
  fn clockOf({domain: int}) -> u32?
  fn setClock({domain: int, source: int}) -> void
```

## Notes
- **`WakeReason` disambiguating *which* GPIO fired** is round-1's addition
  for embedded-display-node ("wake on encoder OR button OR RTC alarm, and
  know which"), and it survives — `match reason.kind` with the pin in the
  payload.
- **`enterSleep(Coldest)` never returns** — RAM is gone and waking is a
  reset, so the cause is recovered via `lastWakeReason()` at boot. The
  signature can't express "does not return"; that's a doc obligation.
- **`deepestFor` before choosing** keeps the Nim design's "ask first, then
  choose — there is no silent downgrade anywhere in this module."
- **Three depths remains a real compression** (STM32 alone has six-plus).
  The Nim design named a `Custom` escape as plausible-but-not-added; that
  judgment is unchanged.
- **The `wakeOn` overload set collapses.** The Nim design had
  `wakeOn(Duration)` / `wakeOn(PinId)` / `wakeOn(SystemTime)` overloaded on
  the argument type so the enum never appeared at a call site. Free
  functions can't overload (`[TK-TY02]`), so `WakeSource` is constructed
  directly with its `kind` — noticeably worse ergonomics, and a concrete
  cost of the no-overloading rule.
