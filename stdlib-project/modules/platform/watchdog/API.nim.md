# platform.watchdog — Nim API

## Purpose
Arm a hardware timer that resets the chip if nothing feeds it in time, and
feed it from the one place in the program that actually knows the system is
still alive. The most repeatable fault-recovery task in firmware
engineering — arm, feed, configure timeout — and every vendor's peripheral
does the same three things underneath, even when the register layout
doesn't match at all.

*New in this pass.* `DOMAINS.md`'s embedded-persona pass found no watchdog
module anywhere in `platform.*`, despite it being more universal across MCU
targets than several already-covered concerns. Recommended rung **A**: small
and stable enough to ship with the compiler outright, the same character
`COMPARISON.md` already gave the priority-queue gap — a cheap, obviously-
missing primitive, not a design risk.

## Protocols implemented
`Watchdog` is `Lifecycle` (`start`/`stop`/`isRunning`) — arming and
disarming the timer is exactly `Lifecycle`'s shape, the same resolution
`platform.power::PowerDomain` already uses. Feeding it is a domain verb;
"prove you're still alive" has no structural analogue.

## The API

```nim
type
  Watchdog* = object            ## Lifecycle
  ResetCause* = enum
    rcPowerOn, rcWatchdog, rcSoftware, rcBrownout, rcExternalPin, rcUnknown
    ## `rcUnknown` exists because not every vendor's reset-cause register is
    ## fully decodable — an honest "couldn't tell" beats a guessed value,
    ## the same reasoning `platform.power::WakeReason` already states for
    ## its own `ColdStart` case.

proc newWatchdog*(timeout: Duration): Watchdog
  ## Configures the timeout but does not arm it — `start` does that,
  ## separately, so a program can finish its own bring-up sequence before
  ## the clock starts running against it.

proc start*(w: var Watchdog): bool     ## Lifecycle: arms the timer
proc stop*(w: var Watchdog): bool
  ## Disarming is legal wherever the silicon allows it and raises where it
  ## doesn't — some vendors' watchdogs are write-once-armed by design, and
  ## this module reports that honestly rather than pretending `stop` always
  ## works.
proc isRunning*(w: Watchdog): bool

proc feed*(w: var Watchdog)
  ## Resets the countdown. The one call a correct program makes from
  ## exactly the place that knows the main loop, or every task it depends
  ## on, actually completed a cycle — never from a timer interrupt that
  ## fires unconditionally, which would defeat the whole point.

proc timeRemaining*(w: Watchdog): Duration
  ## How close the next reset is. Meant for a log line or a diagnostic
  ## build, not for control flow — checking this instead of calling `feed`
  ## on schedule reintroduces the bug the watchdog exists to catch.

proc lastResetCause*(): ResetCause
  ## Read once at boot, from `platform.boot`'s reset path — the same
  ## "read the cause register before anything else touches it" ordering
  ## `platform.power::lastWakeReason` already establishes.
```

## Friendly-naming notes

| Vendor/CMSIS convention | Nim name | Why |
|---|---|---|
| `IWDG_Init` / `WDT_Enable` (per-vendor init) | `newWatchdog(timeout)` + `start(w)` | configuration and arming split into two calls, the same separation `platform.power::PowerDomain` already gives "power the block up" |
| `IWDG_ReloadCounter` / `wdt_reset()` | `feed(w)` | one word, not a vendor's register-operation name |
| `RCC_GetFlagStatus(RCC_FLAG_IWDGRST)` | `lastResetCause()` | reads as the question asked, not the register bit checked |
| a raw reset-cause bitmask | `ResetCause` enum | closed, exhaustive, with `rcUnknown` as the honest escape rather than a silently-wrong guess |

## In use

```nim
# embedded-sensor-node-style main loop: feed only after the cycle that matters completes
var wd = newWatchdog(timeout = 2.seconds)
discard wd.start()

while true:
  let reading = i2c.get(SensorAddr, TemperatureReg, timeout = 100.ms)   # platform.hal
  reading.ifSome(r): report(r)
  wd.feed()                          # only reached if the read above didn't hang

# at boot, before anything else runs
if lastResetCause() == rcWatchdog:
  log.warn("recovered from a watchdog reset — last cycle hung")
```

## Vocabulary exceptions
`feed` and `lastResetCause` are domain verbs — "prove liveness" and "why did
we just restart" have no structural equivalent among the nine protocols, the
same reasoning `platform.power` already gives for `enterSleep`.

## Honest limits
- **Windowed watchdogs are not modeled.** Some vendors' peripherals reject a
  feed that arrives *too early*, not just too late, as a way of catching a
  runaway loop that feeds constantly without doing real work. `feed` here
  assumes the simpler "any feed before timeout is fine" shape; a windowed
  variant is a plausible future `WindowedWatchdog` type, not added
  speculatively because no validated app in this project's set needs it.
- **Multiple independent watchdog peripherals per chip are out of scope.**
  Several MCUs ship both an independent watchdog and a windowed one on the
  same die; this module's `newWatchdog` assumes there is exactly one worth
  naming. Vendors with more get to construct more than one `Watchdog`
  value, which works today, but the module makes no claim about which
  physical peripheral a second construction targets.
