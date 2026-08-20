# platform.power — Nim API

## Purpose
Say "go as quiet as you can, but wake me for any of these things," and be told which one actually happened. Also clock sources and switching unused peripheral blocks off entirely.

## Protocols implemented
`PowerDomain`: `Lifecycle` (`start`/`stop`/`isRunning`) — a power domain is a thing you turn on and off, which is exactly what `Lifecycle` names. `ClockTree` uses `get`/`set` with the clock domain as the locator. Sleep entry is a domain verb.

## The API

```nim
type
  SleepDepth* = enum
    Light      ## CPU halted, clocks and peripherals live. Wakes fastest.
    Deep       ## most clocks gated, RAM kept. `enterSleep` returns here.
    Coldest    ## RAM not kept — waking *is* a reset, so `enterSleep` never returns.

  WakeSource* = object
    case kind*: WakeKind
    of Timer:    after*: Duration        ## relative
    of Gpio:     pin*: PinId
    of Rtc:      at*: SystemTime         ## absolute
    of BusTraffic: peripheral*: PeripheralId

  WakeReason* = object
    case kind*: WakeKind
    of Gpio:       pin*: PinId           ## *which* pin — not merely "a GPIO fired"
    of BusTraffic: peripheral*: PeripheralId
    of Timer, Rtc: discard
    of ColdStart:  discard               ## no live wake source explains this boot

func wakeOn*(after: Duration): WakeSource     ## `wakeOn(30.seconds)`
func wakeOn*(pin: PinId): WakeSource          ## `wakeOn(encoderPin)`
func wakeOn*(at: SystemTime): WakeSource      ## overloaded on the value's type, so the
                                              ## call site never spells the enum

proc enterSleep*(p: var PowerControl, depth: SleepDepth,
                 sources: openArray[WakeSource]): WakeReason
  ## Returns for `Light` and `Deep`. For `Coldest` it **does not return**: RAM is gone
  ## and waking is a reset, so recover the cause with `lastWakeReason()` instead.
  ## Raises if a requested source cannot wake the chip at this depth — never silently
  ## shallower than you asked for.

proc deepestFor*(p: PowerControl, sources: openArray[WakeSource]): SleepDepth
  ## Ask first, then choose. There is no silent downgrade anywhere in this module.

proc lastWakeReason*(p: PowerControl): Option[WakeReason]
  ## Read once at boot, from `platform.boot`'s reset path. `none` on a true first-ever
  ## power-up with no backup domain to have remembered anything.

proc get*(c: ClockTree, domain: ClockDomain): Option[Hertz]   ## queried, never assumed
proc set*(c: var ClockTree, domain: ClockDomain, source: ClockSource)

proc start*(d: var PowerDomain): bool     ## power the block up
proc stop*(d: var PowerDomain): bool      ## gate it off entirely
proc isRunning*(d: PowerDomain): bool
```

## Friendly-naming notes

| Rust name | Nim name | Why |
|---|---|---|
| `SleepDepth::Idle/Standby/Shutdown` | `Light` / `Deep` / `Coldest` | Vendor words that mean different things per vendor became three plain adjectives on one axis, ordered the way they sound. `Coldest` also hints at why nothing comes back. |
| `WakeSource { kind: WakeKind::Timer(d) }` | `wakeOn(30.seconds)` | A constructor per value type. `enterSleep(Deep, [wakeOn(30.seconds), wakeOn(buttonPin)])` needs no enum spelled at any call site. |
| `WakeReason::PowerOnReset` | `ColdStart` | "Power-on reset" is the register bit's name; "cold start" is the situation you are actually in. |
| `deepest_available(wake)` | `deepestFor(p, sources)` | Reads as the question ("deepest for these sources"), and puts the target first per the argument rule. |
| `last_wake_reason()` | `lastWakeReason()` | Kept — already exactly right. |
| `ClockTree::frequency(d) -> u32` | `get(c, domain): Option[Hertz]` | The structural `get`, and `Hertz` instead of a bare `u32` that could be anything. |
| `PowerDomain::enable/disable` | `start` / `stop` | `Lifecycle`, unchanged, for free. |

## In use — embedded-display-node

```nim
let reason = power.enterSleep(Deep, [wakeOn(encoderPin), wakeOn(buttonPin),
                                     wakeOn(nextAlarm)])
case reason.kind
of Gpio:
  if reason.pin == encoderPin: menu.adjust(encoder.readDelta())
  else:                        menu.choose()
of Rtc: clockFace.redraw()
else:   discard
```

And the reset path, for the depth that never returns:

```nim
power.lastWakeReason().ifSome(r):
  if r.kind == ColdStart and not backup.isReady(): rtc.setFromDefault()
```

## Vocabulary exceptions
`enterSleep`, `deepestFor`, `lastWakeReason` and `wakeOn` are domain verbs — "put the silicon in a quieter state" has no structural analogue, and expressing it as `set(power, depth)` would hide that the call blocks, may not return, and hands back a result. They keep the argument order (target, then depth, then the source list).

## Honest limits
- **Three depths is a real compression.** STM32 alone has six-plus modes trading wake latency against retained state. If a second vendor's taxonomy does not fold into `Light`/`Deep`/`Coldest`, this is the one place a vendor escape hatch (a `Custom` depth carrying a raw code) is plausible — not needed yet, and deliberately not added speculatively.
- **`WakeReason` reports one cause.** Real wake-status registers can latch several bits when two sources assert in the same tick. The answer here is that you re-check the others you care about after waking, which is cheap for a GPIO level or an RTC flag and might not be for something else. A deliberate simplification, not a proven-sufficient one.
- **`ColdStart` and `platform.boot`'s `isReady()` answer different questions** and you usually need both: one says how the chip restarted, the other says whether the persisted state believes itself valid. A `ColdStart` with a backup battery already fitted is a cold case for power and a warm case for the RTC.

**Nim-specific:** `WakeSource`/`WakeReason` are ordinary `case object`s — no allocation, no vtable, and `case reason.kind` gets exhaustiveness checking from the compiler, so adding a `WakeKind` variant later breaks every incomplete `case` at compile time instead of falling through at three in the morning.
