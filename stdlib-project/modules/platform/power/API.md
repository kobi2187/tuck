# platform.power

## Purpose
Sleep-mode selection, clock-tree configuration, and power-domain control, giving application code a portable way to say "enter the lowest-power state that still satisfies these wake conditions" without hand-coding vendor power-control registers.

## Design lineage
Modeled on Zephyr's power management subsystem (`pm_state_force`, device power-domain runtime PM, policy-driven idle-state selection) for the portable, policy-based API shape, with STM32 HAL's power API (`HAL_PWR_EnterSTOPMode`, clock-tree `RCC` configuration) used as the vendor-level precedent for what a concrete implementation actually has to configure underneath — named explicitly per the assignment as the vendor-level model this trait must remain implementable against.

## Proposed API
```
enum SleepDepth {
    Idle,        // CPU halted, peripherals/clocks running (fastest wake)
    Standby,     // most clocks gated, RAM retained, wake on timer/pin/bus
    Shutdown,    // RAM not retained except a small backup domain (slowest wake)
}

struct WakeSource {
    kind: WakeKind,   // Timer(Duration) | Gpio(PinId) | Rtc(SystemTime) | BusActivity(PeripheralId)
}

// The return type of enter_sleep — which of the requested WakeSource entries
// actually fired. Mirrors WakeKind's shape so every WakeSource variant maps to
// exactly one WakeReason variant, and carries enough identity (PinId) to tell two
// sources of the same kind apart (e.g. two separate GPIO wake pins).
enum WakeReason {
    Timer,
    Gpio(PinId),        // which pin's edge fired — not just "a GPIO fired"
    Rtc,
    BusActivity(PeripheralId),
    PowerOnReset,        // no live WakeSource explains this boot: a true cold start
}

trait PowerController {
    type Error;
    fn enter_sleep(&mut self, depth: SleepDepth, wake: &[WakeSource]) -> Result<WakeReason, Self::Error>;
    // Returns normally for SleepDepth::Idle and SleepDepth::Standby, where execution
    // resumes at the point enter_sleep was called. For SleepDepth::Shutdown this
    // function DOES NOT RETURN: RAM is not retained, so waking is architecturally a
    // reset. Code that requests Shutdown must recover the wake cause after reset via
    // last_wake_reason(), not from this call's result.
    fn deepest_available(&self, wake: &[WakeSource]) -> SleepDepth;
    // ^ some wake sources are unavailable below a given depth (e.g. BusActivity
    //   requires Idle on many parts) — queried explicitly, never silently downgraded.
    fn last_wake_reason(&self) -> Option<WakeReason>;
    // Queried once at boot (typically from within platform.boot's reset_handler
    // contract, before or during PreInit) to recover why a Shutdown-depth sleep
    // ended, since enter_sleep itself never returned in that case. Returns None on
    // a true power-on-reset with no relevant prior sleep state (e.g. first-ever
    // power-up, backup domain not yet present).
}

trait ClockTree {
    fn set_source(&mut self, domain: ClockDomain, source: ClockSource) -> Result<(), ClockError>;
    fn frequency(&self, domain: ClockDomain) -> u32;   // Hz, queried not assumed
}

trait PowerDomain {
    fn enable(&mut self) -> Result<(), PowerError>;
    fn disable(&mut self);   // gate power to an unused peripheral block entirely
}
```

## Key design decisions
- **Revision (embedded-display-node): `WakeReason` — referenced in prose since the first draft but never actually spelled out as a type — is now a concrete enum, and `last_wake_reason()` is added to handle the case where `enter_sleep` never returns.** This is not the redesign the module's own "Open questions" section anticipated (a `SleepDepth::Custom(u8)` vendor escape hatch, or a rework of `enter_sleep`'s signature to accept a list) — `enter_sleep(depth, wake: &[WakeSource])` already accepted a *set* of wake sources from the first draft, because the sensor node's BLE-advertisement timer plus sample timer already forced `WakeSource` to be a list rather than a single value (see the original validation note below). What the sensor node's single-timer-dominant use case never exposed is that the doc discussed "the implementation returns *which* source actually fired" without the returned type ever being defined, and that a single value type mixing all four `WakeKind` variants needs a way to disambiguate two sources of the *same* kind — embedded-display-node has two independent GPIO wake sources (encoder and button), and `match reason { WakeReason::Gpio(pin) => ... }` only works if `WakeReason::Gpio` carries the `PinId`, not just the fact that some GPIO fired. Second, and genuinely new: embedded-display-node is the first app in this project to make `SleepDepth::Shutdown` a live possibility (RAM-retained `Standby` is enough for its actual power/latency tradeoff, but a device this power-sensitive is exactly the kind of thing that would consider `Shutdown` between long idle stretches), which exposes that `enter_sleep`'s return-a-`WakeReason` contract silently assumes execution resumes at the call site — true for `Idle`/`Standby`, false for `Shutdown`, where waking is a reset and nothing can "return" a value across it. `last_wake_reason()`, queried from the reset path instead, is the fix, and it is the direct bridge between this module and `platform.boot`'s revised reset contract (see that module) — the same "was the RTC/backup state actually preserved, or do I need to reinitialize" question `platform.boot` resolves with `PersistentRegion::is_initialized()` has its power-side counterpart here in `WakeReason::PowerOnReset` vs. a genuine wake-from-Shutdown reason.
- **`enter_sleep` takes an explicit `&[WakeSource]` list and returns `WakeReason`**, rather than a single opaque "sleep(depth)" call — the caller must state up front what should wake the device, and the implementation returns *which* source actually fired, because application code (the sensor node's sampling loop) needs to distinguish "woke because the timer fired, take a sample" from "woke because of unrelated bus activity, go back to sleep" without probing hardware status registers itself.
- **`deepest_available` is queried, never silently applied.** A tempting alternative is for `enter_sleep(Standby, wake)` to silently fall back to `Idle` if `Standby` can't satisfy the requested wake sources on a given chip — rejected, because silent downgrade would mean the same application code draws different (and untested) power on different silicon with no compile-time or even log-time signal, which directly violates Principle 5's "nothing hidden" for this tier; the caller must ask first and choose explicitly.
- **`ClockTree` and `PowerController` are separate traits, not one combined "power" trait**, because clock configuration is typically a one-time (or rare) init-time concern while sleep-mode entry/exit happens every sampling cycle — bundling them would force every sleep-mode call site to also carry clock-tree generic parameters it doesn't use.

## Validated by applications
The embedded-sensor-node's central power scenario — "wake every N seconds, sample, sleep again" — is exactly what exposed the rtos/power boundary problem described in `platform.rtos`'s own validation section: a naive design where `platform.rtos::task_sleep(Duration)` is solely responsible for "sleep" cannot express *hardware* sleep-mode depth at all (an RTOS-level `task_sleep` on a cooperative or preemptive scheduler just yields the CPU to other tasks or busy-waits; it says nothing about whether the MCU core clock-gates or drops to STOP mode), so the app's actual power requirement — enter `Standby` and wake only on the sample-interval timer — could not be satisfied by `rtos` alone. This module's `enter_sleep(SleepDepth::Standby, &[WakeSource::Timer(interval)])` is the fix: it is called from *within* whatever `platform.rtos::PeriodicTimer` implementation is active (bare-metal or real-RTOS-backed), so `rtos` owns "what runs and when" while `power` owns "what physical state the silicon is in while waiting," and the two compose without either module needing to know the other's internals. The app's BLE advertisement requirement adds a second wake source in practice (the radio needs periodic wake to advertise, distinct from the sample timer), which is why `WakeSource` is a list, not a single value, from the first draft — a single-wake-source design would already have been insufficient for this one device. On Part V: `SleepDepth` as three named tiers (rather than STM32 HAL's much finer-grained `SLEEP`/`STOP0`/`STOP1`/`STOP2`/`STANDBY`/`SHUTDOWN`) is a real compression, and it is untested whether three tiers remain sufficient once a second, different vendor's part (with a different depth taxonomy) is validated — this is the one place in `power` where a future escape hatch (a vendor-specific `SleepDepth::Custom(u8)` variant) is plausible, not yet needed.

embedded-display-node is the harder of the two validation cases this module has seen, and it is worth being precise about what it does and does not force. It does *not* force a redesign of `enter_sleep`'s signature — `&[WakeSource]` already generalizes past a single source, and `deepest_available(&[WakeSource])` already computes the achievable depth for an arbitrary combination, so the multi-source case (encoder OR button OR RTC alarm) is expressible exactly as written: `enter_sleep(SleepDepth::Standby, &[WakeSource::Gpio(encoder_pin), WakeSource::Gpio(button_pin), WakeSource::Rtc(next_alarm)])`. Where the sensor node validated "the list can hold more than one source" (its BLE radio's advertising interval plus its sample timer), embedded-display-node validates something stricter: that the *returned* `WakeReason` can actually disambiguate three heterogeneous sources, two of which share a `WakeKind` variant (`Gpio`) and differ only by `PinId`. A design that returned, say, a bare `WakeKind` enum without the pin identity — which is exactly what the sensor node's single-GPIO-adjacent (LED output, not interrupt input) use would never have caught — would have left application code unable to tell "the encoder moved, update the menu selection" from "the button was pressed, select the current item" without a secondary poll of both pins after every wake, defeating the purpose of the typed return value. This is why `WakeReason::Gpio(PinId)` carrying identity, not just kind, is the load-bearing fix here, not a nice-to-have. Separately, embedded-display-node's RTC alarm is the first use in this project of `WakeKind::Rtc(SystemTime)` (the sensor node used only `Timer(Duration)`, a relative interval) — validating that the enum's existing absolute-alarm variant is what a "wake at a specific wall-clock time to refresh a displayed clock" requirement actually needs, with no change required there. The genuinely new, harder finding is the `Shutdown`-depth return-path gap described above: no app before this one made `enter_sleep`-never-returns a live concern, because the sensor node never had a reason to consider anything past `Standby`.

## Open questions / risks
The three-tier `SleepDepth` enum is the biggest untested compression in this module — real silicon (STM32's six-plus modes, for one) has finer gradations trading wake latency against retained state, and collapsing them risks either being too coarse to hit real power budgets or eventually growing vendor-specific depth variants that erode the portable enum the same way Part V predicts for `hal`.

A second, genuinely unresolved risk surfaced by embedded-display-node: `WakeReason` as designed returns a single primary cause, but real wake-status registers on some silicon latch *multiple* pending bits if two sources assert close together (e.g. the RTC alarm fires within the same tick the button is pressed) — this design's answer is that `WakeReason` reports one reason and application code is expected to re-check the others it cares about after waking (cheap here, since GPIO/RTC state is just a normal read once awake), rather than inventing a fixed-capacity multi-reason return type. That is a real, deliberate simplification, not a proven-sufficient one: it has not been checked against a specific vendor's wake-status-register semantics, and a future device with wake sources that are *not* cheap to re-poll after the fact (unlike a GPIO level or an RTC flag) could break it. Named here rather than silently resolved.
