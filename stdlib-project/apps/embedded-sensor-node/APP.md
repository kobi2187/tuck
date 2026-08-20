# App: embedded-sensor-node (simulated firmware)

A bare-metal-style firmware design (analyzed, not flashed to real hardware) for a small battery-powered sensor node on a Cortex-M-class microcontroller: read a temperature/humidity sensor over I2C every N seconds, apply a simple moving-average filter, log samples to onboard flash in a ring buffer, blink a status LED, sleep between samples to conserve power, and periodically advertise the latest reading over BLE.

## Why this is a good validation target
Every other app in this set assumes a hosted OS. This is the only app that exercises Tier 4 (`platform.*`) end-to-end and validates the claim from Part IV that the same language can serve both this and, say, `chat-server` — via `core` + `alloc` + `platform`, skipping `sys`/`std` entirely.

## Features (as a design exercise)
- I2C sensor read with timeout/retry (bus errors are common and must not hang the device).
- Fixed-size ring buffer of samples in flash, wear-conscious (avoid rewriting the same flash sector every sample).
- Simple digital filter (moving average) applied to raw readings.
- GPIO-driven status LED (heartbeat blink, fault pattern on sensor error).
- Sleep between samples using the lowest power mode that still wakes on a timer.
- Periodic BLE advertisement of the latest reading (connectionless, minimal power cost).
- Startup/init sequence and a documented memory layout (flash for code+log, RAM for buffers).

## Modules exercised
| Tier | Module | Why |
|---|---|---|
| platform | `platform.hal` | GPIO (LED), I2C (sensor), ADC (battery voltage) via portable traits |
| platform | `platform.rtos` | periodic sampling task, timer-driven wakeups — even if the final build is a bare-metal loop, the same task API should work if a real RTOS is later dropped in |
| platform | `platform.interrupt` | I2C/timer interrupt handling, critical sections around the ring-buffer write |
| platform | `platform.power` | sleep-mode selection, wake-on-timer configuration |
| platform | `platform.boot` | memory layout (flash log region vs. code vs. RAM), reset/init sequence |
| platform | `platform.dsp` | the moving-average filter — deliberately a trivial case to check the module isn't over-built for it |
| platform | `platform.net.lowpower` | BLE advertisement |
| platform | `platform.libc-shim` | whatever minimal libc surface (if any) the build depends on |
| core | `core.types` / `core.slice` / `core.error` | everything at this layer, since no OS or heap is assumed to exist |
| alloc | `alloc.allocator` | if used at all, a fixed arena sized at compile time — never a general-purpose heap |

## Anticipated API stress points
This app is where Part V's own stated risk shows up concretely: does `platform.hal`'s trait set actually stay stable and vendor-neutral across "read a sensor over I2C with a timeout," or does the first real device (a sensor with a quirky multi-step init sequence) immediately force vendor-specific escape hatches that erode the portability the trait promised? `platform.rtos`'s claim to work identically bare-metal or under a real RTOS is also directly testable here.
