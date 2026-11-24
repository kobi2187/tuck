# Tuck on bare metal

Tuck programs on Cortex-M microcontrollers: checked by the compiler, built
freestanding, run under QEMU. Experimental: Nim backend only on metal, two
QEMU boards, no real hardware yet. What works and what is next is in
`ROADMAP.md`; why, in `VISION.md`.

## Read in this order

1. **`VISION.md`**: what "first-class bare metal" means, the reuse rule
   (libraries declare, applications bind), the pillars, and the owner
   decisions still open.
2. **`ROADMAP.md`**: where it stands, the phases with exit criteria, the
   critical path, and the traps. The only file that says what to do next.
3. **`DESIGN-interrupt-events.md`**: interrupts as registry events, the exact
   rules for interrupt code (IRQ-1..9) and for every policy (POL-1..6),
   with the owner's rulings recorded.
4. **`REVIEW-2026-11-22.md`**: the senior-embedded review: what it found,
   what it fixed, what is still open.
5. **`PROGRAMS-2026-11-22.md`**: three programs on real parts (irrigation,
   MP3 recorder, quad) in `tests/metal/devices/`: what read well, the
   frictions, the blockers, the compiler bugs they found.
6. `archive/`: the plans these replaced. Rationale and experiment log only.

## Where things live

| Path | What |
|---|---|
| `boards/<board>/` | one directory per board: `board.ld` (memory map; defines `_estack`, the initial SP) and `board.conf` (QEMU machine, CPU, console) |
| `boards/common/` | shared by every board: `startup_cortex_m.c` (vector table, reset, fault recorder, `tuck_fatal`), `semihosting.c` (the QEMU console and exit: `tuck_board_puts`, `tuck_board_exit`), `stubs.c` |
| `boards/picolibc/` | `build.sh` fetches picolibc 1.8.12 (pinned SHA-256) and builds the Thumb `libc.a` into `build/picolibc/` |
| `tools/metal/` | `qemu-run.sh` (what `tuck sim` runs: `tuck b --board` + QEMU), `host-run.sh` (`tuck sim --host`), `gdb-run.sh` (break on the target) |
| `tools/svd2tuck/` | CMSIS-SVD → Tuck `register` module generator, with its own docs and generated STM32F103 modules |
| `tests/metal/` | the metal programs; `host_sim/` holds their host shims, one twin per backend |
| `tests/suites/metal_runtime.nim`, `sim_tick`, `sim_host`, `crash_decode`, `isr_discipline`, `svd_import`, `timing_report`, `error_policy` | the suites that pin it |

## Run it

Needs `qemu-system-arm`, `arm-none-eabi-gcc`, `meson` + `ninja` (once, for
picolibc), optionally `gdb-multiarch`. Nim 2.2.4 (the CI pin).

```sh
boards/picolibc/build.sh                          # once
./tuck b tests/metal/task_await.tuck --board:lm3s6965evb   # just the ELF
./tuck sim tests/metal/task_await.tuck            # build + boot under QEMU
./tuck sim tests/metal/task_await.tuck --host     # Nim, Odin and D on the host
tools/metal/gdb-run.sh task_await 10              # stop gdb at task_await.tuck:10
./tests/run metal_runtime sim_tick crash_decode isr_discipline error_policy
./tuck audit tests/metal/critical_shared.tuck --isr   # the ISR shared-state table
./tuck timing tests/metal/critical_shared.tuck        # nesting, stack, cycles
```

`tuck sim` options: `--tick:0..10` (fixed QEMU `-icount` shift),
`--time:fast` (shift 10), `--fault:isr-drop`, `--format:json|sarif` for a
decoded crash. Environment: `TUCK_BOARD=lm3s6965evb|stm32vldiscovery`,
`TUCK_SKIP_TUCK_BUILD=1`, `TUCK_OUT_DIR`, `TUCK_STDLIB` (e.g.
`tools/svd2tuck/generated` for `boot_led_svd`).

**Exit status:** main's return value through semihosting; 1 after a fault or
a `PANIC:`; **124 only when the program was still running when the 10 s
window closed**, which is never a pass.

## The programs in `tests/metal/`

| Program | Proves | Where |
|---|---|---|
| `boot_nop`, `boot_led`, `boot_led_svd` | boot; register writes; SVD-generated registers identical to hand-written | QEMU (GPIO not modelled) |
| `hal_led`, `hal_counter`, `hal_button`, `hal_uart_echo`, `two_blinkers`, `platform_hal` | logic and scheduler against host shims | host |
| `actor_mailbox`, `actor_ring` | actors on metal: a ring mailbox per actor, a full ring that waits, one actor sending to another | QEMU and host |
| `bind_irq`, `bind_systick` | `bind`: a pended line through the generated vector table, events delivered after the interrupt; a SysTick event loop sleeping between ticks | QEMU |
| `buffer_dma`, `buffer_stack` | `buffer`: `.address` is the memory a `register` at that address reads; a placed buffer lands word-aligned in RAM; an `at` buffer in the stack reserve fails the link | QEMU |
| `pool_dma`, `pool_stale` | `Pool.address`: each cell a word-aligned RAM address, one block apart; a stale handle panics `TUCK POOL:` | QEMU |
| `uart_rx` | a UART receive interrupt: bytes typed on QEMU's serial port (`TUCK_SIM_INPUT="hello\n" tuck sim ...`) reach an actor through `bind UART0` | QEMU |
| `devices/irrigation`, `devices/recorder`, `devices/drone` | three programs on real parts (`PROGRAMS-2026-11-22.md`); the first two boot and exit 1 with no device on the bus | QEMU (build) and host (simulations) |
| `two_tasks`, `task_await`, `task_fire_forget` | stackless tasks on metal: interleave, await, fire-and-forget | QEMU |
| `irq_marker`, `critical_shared`, `isr_handoff` | `[irq]`, `critical:`, the one-word ISR hand-off (these call their handler directly; `bind_irq` takes a real one) | QEMU |
| `critical_nest` | nested `critical:` keeps interrupts masked; an early `return` unmasks | QEMU |
| `isr_overrun` | a post to a full ISR slot is dropped and counted | QEMU |
| `fault_null_call`, `fault_unaligned` | faults decoded to the Tuck line | QEMU |
| `fault_isr_drop` | "fault injection" by a compile-time flag (to be replaced, roadmap 2.6) | QEMU |
| `clock_advances` (+ module `systick_clock`) | SysTick guest clock on both boards, ticks 0–10 | QEMU |
| `panic_bounds`, `panic_frame_heap` | a failed check stops with `PANIC:` and the Tuck line | QEMU |
| `exit_code` | main's return value is the QEMU exit status | QEMU |
