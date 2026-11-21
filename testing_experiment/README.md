# testing_experiment — stackless coroutines on real metal

Goal: validate that Tuck's stackless concurrency (`--concurrency:stackless`)
can run on a **bare-metal, no-OS microcontroller** (no mmap, no stack
switching, no heap required for the scheduler), starting from the simplest
observable behaviour (an LED) and advancing to a cooperative scheduler
driving multiple stackless tasks.

## Why this is the right test

Stackless (#216) was designed precisely so spec Part 9's "stackless bare-metal
path" stops being separate future work: it removes minicoro's `mmap`'d
virtual stacks and the stack-switching, and a frame is just a struct on the
heap (or, with ruling 4, in a slab or on the stack when counts/sizes are
known at compile time). The open question is whether the generated code +
runtime actually boots and runs on a device with no OS and little RAM.

## Target hardware (chosen for availability + debuggability)

- **Primary:** STM32F103C8 "Blue Pill" (Cortex-M3, 72 MHz, 20 KB SRAM,
  64 KB flash, on-board LED on PC13). Cheap, ubiquitous, well-documented
  memory map.
- **Secondary:** RP2040 (Pico) — dual core, but we use one core; good
  fallback if STM32 tooling is unavailable.
- **Tertiary (host simulation):** compile to the host binary and run under a
  "fake HAL" that maps registers to host memory and prints state. This is
  the only part we can actually execute in this sandbox; it validates logic
  and the scheduler, not the metal.

## Stages (each must pass on host sim before flashing)

| # | File | What it proves |
|---|---|---|
| 1 | `stage1_led.tuck` | Compiles, boots, toggles a GPIO. No concurrency. Baseline. |
| 2 | `stage2_counter.tuck` | Volatile register R/W, saturating/trapping types, loops, timing. |
| 3 | `stage3_button.tuck` | Input register, edge handling, debounce without allocation. |
| 4 | `stage4_uart_echo.tuck` | `register` + volatile + a tight poll loop; bytes cross as values. |
| 5 | `stage5_stackless_blink.tuck` | Two stackless tasks, each with an `[io]` yield, driving two LEDs. |
| 6 | `stage6_mailbox.tuck` | Actor with a mailbox + `on_full: wait`, under stackless. |
| 7 | `stage7_platform_hal.tuck` | Uses stdlib-project's `platform.hal` (OutputPin group) on SimPin. |

## Bare-metal constraints we must honour

- `--concurrency:stackless` (no minicoro, no mmap).
- `--no-invariants` optional for size; keep invariants on until green.
- No heap in the scheduler path: frames must come from a `pool` or static
  storage (ruling 4). Stage 5 uses a `pool` of frames.
- `register` decls for all MMIO; volatile loads/stores (compiler emits
  `tuckVolatileLoad/Store` on Nim, `intrinsics.volatile_*` on Odin, D volatile).
- `[irq_safe, no_alloc, no_recursion]` on any ISR-shaped fn; stack budget.
- Effects declared everywhere (`[io]` makes the async points).

## Toolchain needed (not present in this sandbox)

- `arm-none-eabi-gcc` / `arm-none-eabi-g++` (or `clang --target=arm-none-eabi`)
- `openocd` or `st-flash` / `picotool` to flash
- `qemu-system-arm -M stm32vldiscovery` (optional, for no-hardware iteration)

Status after the user installed the tools (2026-11-19):

- `qemu-system-arm` 8.2.2 and `arm-none-eabi-gcc` 13.2.1 are now available.
- Attempted a freestanding ARM build of `bare_metal_led.tuck` with
  `--nim:"--os:standalone --cpu:arm --mm:none"` plus a minimal
  `panicoverride.nim` (rawoutput + panic). It gets past Nim's standalone
  requirements and then fails at
  `compiler/tuck_sl.nim(98, 31): undeclared identifier: 'alloc'`.
- Root cause: Tuck's runtime (`tuck_sl`, `tuck_rt`) assumes an OS/allocator
  (alloc, epoll, threads, mmap). There is no freestanding runtime port, so
  no Tuck program — not even the simplest register-only blink — can be
  linked for bare metal today. This is the real blocker, not the toolchain.

So the QEMU pipeline itself is unblocked, but Tuck is not ready to feed it.
Two honest next steps:

1. **Port a freestanding runtime** (a real project): replace `alloc` usage in
   `tuck_sl` with a static pool/arena, drop epoll/threads, provide a
   semihosting `rawoutput`, and gate OS features behind `when not defined(freestanding)`.
   Only then can `bare_metal_led.tuck` link and run under
   `qemu-system-arm -M lm3s6965evb -semihosting`.
2. **Validate the QEMU pipeline independently** (done conceptually): the
   stages already prove under the host sim that the stackless scheduler
   interleaves two tasks with no mmap/stack-switching, which is the property
   the metal target needs. The remaining metal-specific risks are link-time
   (runtime) and timing (SysTick), neither of which needs Tuck changes to
   measure once (1) exists.

Until (1) lands, the host sim in `host_sim/` is the verification surface:
`./tuck b testing_experiment/stage5_stackless_blink.tuck --concurrency:stackless`
builds and runs, printing the interleaved LED lines.

## Host simulation

The fastest loop is:

    ./tuck sim testing_experiment/stage9_minimal_task.tuck --host

That builds against the shims in `host_sim/` and runs locally — no ARM GCC, no
QEMU. By default it runs **all three backends** (Nim, Odin, D) and leaves each
program's stdout in the log so they can be compared byte-for-byte; a compiler
missing from `PATH` is reported `SKIP`. Use `--backend:nim|odin|d` for one.
`stage9_minimal_task` (a task + print) and `stage5_stackless_blink` (two
stackless tasks + HAL) are the pinned three-target cases in
`tests/suites/sim_host.nim`.

**Why the shims exist.** Stages declare their HAL as `extern` fns rather than
raw `register` blocks: the real addresses belong in `hal_stm32.tuck`, while
the host shims print (or return fixed values) and the QEMU build reaches MMIO.
Each shim has three twins — `print_shim.nim/.odin/.d` and
`hal_shim.nim/.odin/.d` — because the FFI spelling *is* the target language:
Nim's `stdout.write`, Odin's `fmt.print` inside one `package host_sim`, D's
`writeln` in a module imported by bare name. The logic is shared; the syntax
never is. `print_shim.nim` gates its semihosting import on
`defined(freestanding)`, so the QEMU build still routes through
`tuck_semihost_write` while the host build uses stdout, with no change to the
freestanding output.

## stdlib-project (the embedded stack)

The active stdlib is `stdlib-project/` (not the legacy `std/`), selected with
`--stdlib:stdlib-project`. Its `platform/` tier is exactly the embedded layer
this experiment wants: `platform.hal` (OutputPin/InputPin/I2cBus/... groups),
`platform.interrupt` (simulated controller), `platform.boot` (memory regions),
`platform.rtos`, `platform.watchdog`, `platform.power`, etc. These are pure
Tuck and compile for any target, so they are the right vocabulary for drivers
that must run on metal. `stage7_platform_hal.tuck` exercises `platform.hal`
against the simulated `SimPin`.

Build any stage against it with:

    ./tuck b testing_experiment/stage7_platform_hal.tuck \\
        --stdlib:stdlib-project --concurrency:stackless

## Verification ladder

1. `./tuck ch stage*.tuck --stdlib:stdlib-project` — type+effect clean.
2. `./tuck b ... --concurrency:stackless` on host sim — runs, prints expected.
3. Cross-compile to ARM with `--nim:"--os:standalone --cpu:arm ..."` or Odin
   cross flags; flash; observe LED. (Blocked on freestanding runtime — see above.)
4. Measure: flash size, SRAM usage (frame pool), jitter of the blink period.

## What "success" looks like

- Stage 1: LED blinks at 1 Hz on the real board.
- Stage 5: two LEDs blink at independent rates driven by two stackless tasks,
  with a measured task-switch cost in the tens of nanoseconds (per the spike)
  and no stack overflow at 20 KB SRAM.
- If it fails: capture the failure mode (link error, hard fault, wrong timing)
  and feed back into `docs/stackless-concurrency.md` "bare-metal path".

---

## Experiment log — freestanding QEMU runs (2026-11-19)

With `qemu-system-arm` 8.2.2, `arm-none-eabi-gcc` 13.2.1 now installed, and
the `freestanding-loop.sh` driver, we got a real bare-metal build running.

### What the script does
- rebuilds `tuck`;
- compiles the stage with `--os:standalone --cpu:arm --mm:none -d:freestanding`
  plus `--cc:gcc --gcc.exe:arm-none-eabi-gcc --threads:off --passC:-mthumb`
  and a template startup + linker script in `boards/`;
- boots the ELF under `qemu-system-arm -M lm3s6965evb`.

### Compiler/runtime changes made in this pass (all gated on `defined(freestanding)`)
- `compiler/tuck_sl.nim`: a static 2 KB bump allocator (`alloc`/`dealloc`),
  `tuckVolatileLoad/Store`, a reactor-free `tuckSlAwaitMain` and `tuckSlOnStack`,
  and `allocShared0` shims — under `when defined(freestanding)`.
- `compiler/tuck_rt.nim`: OS imports (`os`, `times`, `monotimes`, `posix`,
  `tuck_async`) gated off; the stdlib-externs section split into
  `tuck_rt_stdlib_externs.nim` (included only when NOT freestanding); `raise`
  in two cold paths replaced with a halt; batch timeout defaulted to 0.
- `tuck.nim`: `--freestanding` detected from `--nim:` flags; the entry wrapper
  emits a plain `discard tuck_main()` (no libc `quit`/`exit`, no `tuck_async`
  import) and a `tuckSlRunAll()` after main.

### The developer loop: `tuck sim`, `tuck timing`, `tuck decode-crash`

- `tuck sim FILE.tuck` builds the file freestanding and boots it under QEMU in
  one command (about a second), printing the program's semihosting output. It
  exits non-zero on a fault. `--tick:N` (`0..10`, each step doubles virtual ns
  per instruction) sets a fixed QEMU `-icount shift=N,sleep=off`;
  `--time:fast` is the `shift=10` preset. `--fault:isr-drop` injects a dropped
  interrupt at compile time. Set `TUCK_BOARD=lm3s6965evb|stm32vldiscovery` to
  pick the QEMU machine, CPU, linker script and initial stack pointer. When a
  FAULT line appears it prints the decoded crash report automatically and
  exits 1. `tuck sim --host` ignores all QEMU-only flags; see T19.
- `tuck timing FILE.tuck` is the static budget report: worst-case
  **critical-section nesting** per fn and an **approximate worst-case stack**
  along the resolved call graph. `--format:json` and `--format:sarif` feed CI;
  `tuck explain TK-TM01` / `TK-TM02` explain the rules. Stack numbers SUM the
  call path and are a budget flag, not a measurement.
- `tuck decode-crash ELF [PC]` (or `--log:FILE` from a captured QEMU run) turns
  a fault record into a what/why/fix reading: CFSR/HFSR bits in plain language,
  PC/LR resolved through `nm` + `addr2line` to `.tuck` lines when built with
  `--debug-lines`, and `--format:json|sarif` with rule id `TK-CR01` (a warning,
  so a post-mortem report never gates a build). `tuck explain TK-CR01` explains
  it. Text output says explicitly when the stacked PC is imprecise or a null
  target, so a guessed location is never presented as a place to edit.

### Generated register modules (T8)

`tools/svd2tuck/` is a standalone Nim generator: one CMSIS-SVD in, one
importable Tuck module out. It vendors svd2nim's MIT parser front half and an
Apache-2.0 STM32F103 SVD; `./tools/svd2tuck/regenerate.sh` rebuilds both
committed modules. `bare_metal_led_svd.tuck` imports the Blue Pill module and
uses the same five registers as `bare_metal_led.tuck` with no diff in address
or used fields. Run it with:

```sh
TUCK_STDLIB=testing_experiment/tools/svd2tuck/generated \
  ./freestanding-loop.sh bare_metal_led_svd
```

### Guest clock, tick length, and board profiles (T7)

`systick_clock.tuck` is a reusable polled clock: `clock_init(reload)`,
`clock_now() -> u32`, and wrap-safe `clock_elapsed(start, stop)`. QEMU 8.2 does
not emulate the DWT cycle counter (`0xE0001004` reads zero), so the clock uses
SysTick's 24-bit down-counter instead — no interrupt, safe to call from an ISR.
QEMU's ptimer applies `PTIMER_POLICY_NO_IMMEDIATE_RELOAD` (writing `CVR` clears
it; the first reload lands on the next edge), so `clock_init` burns a fixed
1000 reads to warm the counter before it is sampled. `stage17_clock.tuck`
imports the module and prints `CLOCK_OK` when the counter advances.

Two boards are supported via `TUCK_BOARD` (machine, CPU, linker script, initial
SP), and tick length is fixed at any `-icount shift` 0..10:

```sh
./tuck sim testing_experiment/stage17_clock.tuck --tick:0
TUCK_BOARD=stm32vldiscovery ./tuck sim testing_experiment/stage17_clock.tuck --tick:10
```

Both print `CLOCK_OK` and end in the idle loop (`qemu exit: 124`) at shifts 0,
4 and 10. `tests/suites/sim_tick.nim` pins the `--tick` rejection cases and one
scenario per board; it SKIPs when QEMU, the ARM toolchain or vendored picolibc
is absent. The loop script accepts `TUCK_SKIP_TUCK_BUILD=1` and `TUCK_OUT_DIR`
so parallel scenarios neither rebuild `tuck` redundantly nor share a scratch
directory.

### Results (updated 2026-11-21)
| stage | result |
|---|---|
| `stage17_clock.tuck` (both boards, ticks 0/4/10) | **prints `CLOCK_OK`, idle loop, no fault** |
|---|---|
| `bare_metal_nop.tuck` (no tasks) | **boots, runs to idle, no fault** |
| `bare_metal_led.tuck` (register writes) | **boots, runs to idle, no fault** |
| `bare_metal_led_svd.tuck` (SVD-generated registers) | **boots, runs to idle, no fault — identical to hand-written** |
| `stage9_minimal_task.tuck` (one `[io]` task returning a value) | **runs to completion, prints TASK_OK** |
| `stage10_fire_forget.tuck` | **runs to completion, both workers print WORKER** |
| `stage12_critical.tuck` (protected shared state) | **boots, prints CRITICAL_OK** |
| `stage13_isr_spsc.tuck` (ISR-safe handoff) | **boots, prints ISR_SPSC_OK** |
| `stage14_fault.tuck` (deliberate null-call fault) | **decoded: INVSTATE, PC=0 null target, LR names call site** |
| `stage16_precise_fault.tuck` (unaligned store, `CCR.UNALIGN_TRP`) | **decoded: UNALIGNED, PC maps to shim, LR names `stage16_precise_fault.tuck:19`** |
| `stage11_irq_marker.tuck` (clean run) | **prints `IRQ_MARKER_OK`, `tuck sim` exits 0** |
| `tests/run crash_decode` | **12 passed, 0 failed** (11 in `--quick`; DWARF case SKIPs without a backend build) |

### Root cause of the now-resolved blocker
Nim's `nimZeroMem` calls newlib's `memset`, which `arm-none-eabi-gcc` ships in
**ARM state**; Cortex-M is Thumb-only. Fixed by vendoring **picolibc 1.8.12**
(Thumb `memset`) under `testing_experiment/vendor/picolibc/` and linking it via
`boards/build-picolibc.sh`. A second blocker — TLS threadvars not staying
consistent under `--threads:off` — was fixed by making `slHead`/`slTail`/
`tuckSlDriving` plain globals under `defined(freestanding)`.

### Verdict on the question "is pool + slab enough for freestanding?"
No. Pool/slab solve *program storage*, but the compiler runtime's C/libc
dependency (ARM-mode newlib, TLS/`__aeabi_read_tp`, the reactor, `quit`) was the
real gate. A freestanding port needed a Thumb libc + a minimal runtime first;
the Tuck-level pool/slab/frame work was necessary but not sufficient. Both gates
are now cleared on this branch — see the resolved-blocker note above and the
QEMU results in `IMPLEMENTATION-GROUND.md` §7a.
