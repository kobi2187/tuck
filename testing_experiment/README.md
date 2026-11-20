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

`host_sim/` contains a fake HAL that maps the STM32 register addresses to a
host array and prints LED state. Build a stage with:

    cd /home/kl/prog/tuck_lexer
    ./tuck b testing_experiment/stage1_led.tuck --concurrency:stackless

Then replace the generated `main`'s register accesses? No — the register decls
already lower to volatile loads/stores against absolute addresses, which on a
host would segfault. So the host sim instead compiles a *variant* where the
`register` block is swapped for a host-backed shim (see `host_sim/hal_shim.*`).

Concretely: stages are written so the HAL is a set of `extern` fns
(`ledOn`, `ledOff`, `delayMs`, `uartPutc`) rather than raw `register` blocks
in the stage body, so the same `.tuck` compiles on both host (shim
implementations print) and target (shim implementations hit MMIO). The
`register` declarations are kept in `hal_stm32.tuck` for reference and
documentation of the real addresses.

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

### Results (updated 2026-11-20)
| stage | result |
|---|---|
| `bare_metal_nop.tuck` (no tasks) | **boots, runs to idle, no fault** |
| `bare_metal_led.tuck` (register writes) | **boots, runs to idle, no fault** |
| `stage9_minimal_task.tuck` (one `[io]` task returning a value) | **runs to completion, prints TASK_OK** |
| `stage10_fire_forget.tuck` | **runs to completion, both workers print WORKER** |
| `stage12_critical.tuck` (protected shared state) | **boots, prints CRITICAL_OK** |
| `stage13_isr_spsc.tuck` (ISR-safe handoff) | **boots, prints ISR_SPSC_OK** |
| `stage14_fault.tuck` (deliberate null-call fault) | **fault captured: prints FAULT PC=... CFSR=... HFSR=...** |

### Root cause of the now-resolved blocker
Nim's `nimZeroMem` calls newlib's `memset`, which `arm-none-eabi-gcc` ships in
**ARM state**; Cortex-M is Thumb-only. Fixed by vendoring **picolibc 1.8.12**
(Thumb `memset`) under `testing_experiment/vendor/picolibc/` and linking it via
`boards/build-picolibc.sh`. A second blocker — TLS threadvars not staying
consistent under `--threads:off` — was fixed by making `slHead`/`slTail`/
`tuckSlDriving` plain globals under `defined(freestanding)`.

### Root cause of the remaining blocker (important)
Nim's C output calls **newlib's `memset`** (through `nimZeroMem`) to clear task
frames/slots. `arm-none-eabi-gcc`'s bundled `libc.a` is precompiled in **ARM
state** (`e92d4030` etc.). Cortex-M3 is **Thumb-only**: a Thumb→ARM `bl` becomes
a `bx` to an ARM target, which the core cannot execute. Simple programs avoid
`memset` and run; any program with tasks (frames/slots) hits it. The earlier
"START printed then faulted" symptom was this same class (libc `exit`/malloc
dragged in by `quit`, also ARM-mode).

**Fixes needed (add to the plan):**
1. Link a **Thumb-built C library** (e.g. `picolibc`, or rebuild newlib with
   `-mthumb`) instead of the bundled ARM `libc.a`. This is the single biggest
   blocker for real metal.
2. Provide proper **vector-table handlers** for all Cortex-M exceptions, not
   just the reset vector — currently a BKPT/HardFault jumps to garbage because
   the table has only two entries.
3. Keep `nimZeroMem` inlined / implement a Thumb `memset` so no ARM libc is
   reached.

### Verdict on the question "is pool + slab enough for freestanding?"
No. Pool/slab solve *program storage*, but the compiler runtime's C/libc
dependency (ARM-mode newlib, TLS/`__aeabi_read_tp`, the reactor, `quit`) is the
real gate. A freestanding port needs a Thumb libc + a minimal runtime first;
the Tuck-level pool/slab/frame work is necessary but not sufficient.
