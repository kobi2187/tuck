# testing_experiment — Tuck on bare metal

The bare-metal track: Tuck programs on Cortex-M microcontrollers, checked by
the compiler and run under QEMU. Experimental and not merged to `main`;
Phase 0 of the roadmap moves it to `boards/`, `tools/metal/` and
`tests/metal/` and merges it.

## Read in this order

1. **`VISION.md`**: what "first-class bare metal" means, the architecture,
   the pillars, and the decisions the owner needs to make (D1–D11).
2. **`ROADMAP.md`**: where it stands, the phases with exit criteria, the
   critical path, and the traps. The only file that says what to do next.
3. **`DESIGN-EVENTS.md`**: the leading design for interrupts, as registry
   events: one semantics, a hosted world and a metal world. Input to the
   design round (roadmap 1.0).
4. **`REVIEW-2026-11-22.md`**: the evidence. What a senior-embedded review
   found, what it fixed, and what is still open, each with how it was
   reproduced.
5. `archive/`: the four earlier plans and the old README. Rationale and
   experiment log only; do not plan from them.

## Run it

Needs `qemu-system-arm`, `arm-none-eabi-gcc`, `meson` + `ninja` (once, for
picolibc), and optionally `gdb-multiarch`. Nim 2.2.4 (the CI pin).

```sh
./testing_experiment/boards/build-picolibc.sh          # once: Thumb libc.a
./tuck sim testing_experiment/stage9_minimal_task.tuck # build + boot in QEMU
./tuck sim testing_experiment/stage9_minimal_task.tuck --host   # Nim, Odin, D
./testing_experiment/gdb-loop.sh stage9_minimal_task 10          # break on target
./tests/run metal_runtime sim_tick crash_decode isr_discipline   # the metal gate
./tuck audit testing_experiment/stage12_critical.tuck --isr      # shared-state table
./tuck timing testing_experiment/stage12_critical.tuck           # nesting, stack, cycles
./tuck decode-crash ELF --log:FILE                               # a captured fault
```

`tuck sim` options: `--tick:0..10` (fixed QEMU `-icount` shift),
`--time:fast` (shift 10), `--fault:isr-drop`, `--format:json|sarif` for the
decoded crash. `TUCK_BOARD=lm3s6965evb|stm32vldiscovery` picks the board;
`TUCK_SKIP_TUCK_BUILD=1` skips the `tuck` rebuild; `TUCK_OUT_DIR` sets the
scratch directory.

**Exit status.** A run ends through semihosting with main's return value:
0 is success, a program's own number is its own, 1 follows a fault or a
`PANIC:`, and **124 means still running when the 10 s window closed**: a
firmware main loop, or a hang. It is never success.

## Layout

| Path | What |
|---|---|
| `stage*.tuck`, `bare_metal_*.tuck` | the stages; a `fn main` returning `int` is a program, run-gated by exit status |
| `systick_clock.tuck`, `hal_stm32.tuck` | reusable modules (SysTick clock; reference STM32 addresses) |
| `boards/` | startup, linker scripts, semihosting asm, picolibc cross file and build script |
| `host_sim/` | shims for the host sim, one twin per backend (`.nim`, `.odin`, `.d`) |
| `tools/svd2tuck/` | CMSIS-SVD → Tuck `register` module generator, with its own docs |
| `freestanding-loop.sh`, `host-loop.sh`, `gdb-loop.sh` | the loops `tuck sim` and the suites drive |
| `vendor/picolibc/` | pinned picolibc 1.8.12 source (to become a fetched tarball, roadmap 0.3) |

## Stages and what each proves

| Stage | Proves | Rung |
|---|---|---|
| `bare_metal_nop`, `bare_metal_led`, `bare_metal_led_svd` | boot, register writes, SVD-generated registers | qemu (GPIO not modelled) |
| `stage1`–`stage7` | host-sim programs: LED, counter, button, UART echo, two stackless blinkers, mailbox, `platform.hal` | host |
| `stage8`, `stage9`, `stage10` | stackless tasks on metal: interleaving, await, fire-and-forget | qemu |
| `stage11`–`stage13` | `[irq]`, `critical:`, one-word ISR hand-off (ISRs are called, not taken) | qemu |
| `stage14`, `stage16` | null-branch and precise faults decoded to the Tuck line | qemu |
| `stage15` | "fault injection" by a compile-time flag (to be replaced, roadmap 2.6) | qemu |
| `stage17` | SysTick guest clock, both boards, ticks 0–10 | qemu |
| `stage18` | nested `critical:` keeps interrupts masked; early `return` unmasks | qemu |
| `stage19` | ISR slot drops and counts a post to a full slot | qemu |
| `stage20`, `stage21` | out-of-bounds index and frame-heap exhaustion: `PANIC:` + the Tuck line | qemu |
| `stage22` | main's return value is the QEMU exit status | qemu |
