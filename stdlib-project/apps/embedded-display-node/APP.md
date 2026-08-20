# App: embedded-display-node (second embedded device, deliberately different)

A second bare-metal-style firmware design, chosen specifically to *differ* from `embedded-sensor-node` in ways that stress-test `platform.*` on axes the first device never touched: a small SPI e-ink or LCD display (not I2C), a rotary encoder with a push-button for input (edge-triggered GPIO interrupts, not polled ADC), a battery-backed RTC over I2C that must survive resets, and a deep-sleep-between-updates power profile driven by user input rather than a fixed timer.

## Why this is a good validation target
`embedded-sensor-node` validated `platform.hal` for I2C and polled ADC, `platform.rtos` for periodic timer-driven sampling, and `platform.power` for fixed-interval sleep. This device deliberately exercises the parts of the same trait sets that device never touched: SPI (a different bus entirely), edge-triggered interrupts as a *wake source* (not just a critical-section concern), and a persistent RTC that must be initialized once and read across resets — the single best test yet of `platform.boot`'s promise that "init happens once" actually holds when part of the hardware state (the RTC) is intentionally *not* reset.

## Features (as a design exercise)
- SPI-driven display: partial and full refresh, a simple framebuffer, and power-down of the display controller between updates.
- Rotary encoder + button on GPIO, debounced, driving a small menu UI on the display.
- I2C RTC read/write, used both for a displayed clock and to timestamp logged events without needing external time sync.
- Wake sources: encoder movement (interrupt) OR RTC alarm (periodic) OR button press — whichever occurs first should wake the device, and the firmware needs to know *which one* woke it.
- Deep sleep between any activity, waking to update the display then sleeping again — power budget dominated by "how long can it stay asleep," not "how fast can it compute."

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| platform | `platform.hal` | SPI (display) exercised for the first time in this project; GPIO edge-interrupt configuration for the encoder/button, distinct from `embedded-sensor-node`'s polled-only GPIO use |
| platform | `platform.interrupt` | encoder/button as genuine asynchronous wake sources, not just a critical-section-around-a-buffer concern |
| platform | `platform.power` | multi-source wake (timer OR interrupt OR button) — a materially harder case than the first device's single timer-driven wake |
| platform | `platform.boot` | RTC state must NOT be reset across a firmware reset/reflash — tests whether the boot/init model can distinguish "cold boot" from "waking from sleep" from "reset while RTC keeps running" |
| platform | `platform.rtos` | event-driven task scheduling (react to whichever wake source fired) rather than the first device's simple periodic loop |
| core | `core.error` | SPI transfer errors, RTC read failures (e.g. dead backup battery) |
| alloc | `alloc.allocator` | small fixed arena for the framebuffer, sized at compile time |

## Anticipated API stress points
`platform.power`'s `enter_sleep`/`WakeReason` design (established by `embedded-sensor-node`) is directly tested here: can it express "wake on any of these N sources, and tell me which one fired," or does it only support a single wake source per sleep call, forcing an awkward polling loop that defeats the purpose of deep sleep? `platform.boot`'s memory-region model also gets a genuine second test — does its `MEMORY_MAP` type have any way to mark a peripheral (the RTC) as "not reset," or does the abstraction implicitly assume all state is reinitialized at boot, which would be wrong for this device and possibly others like it (backup-battery-RAM designs are common in real embedded products).
