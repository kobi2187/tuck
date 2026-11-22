> **ARCHIVED 2026-11-22.** Superseded by `../VISION.md` (what and why) and
> `../ROADMAP.md` (what next). Kept for its rationale, its recorded traps and
> its observed QEMU results; do not plan from it. Where it disagrees with the
> two new files, they win.

# Plan: Tuck on bare metal (freestanding ARM Cortex-M)

Status: planning. Board chosen for the first port: **STM32F103C8 "Blue Pill"**
(Cortex-M3, 72 MHz, 20 KB SRAM, 64 KB flash, LED on PC13 active-low). QEMU
development target: **lm3s6965evb** (Cortex-M3, semihosting, well-supported by
qemu-system-arm) so the pipeline can be exercised without hardware; a second
board package ports the same code to the Blue Pill's registers.

## Goal

Compile and run a Tuck program on a bare-metal ARM Cortex-M with **no OS, no
heap, no mmap, no threads**, using the stackless concurrency that already exists
(`--concurrency:stackless`), and prove it under QEMU. The first milestone is
`bare_metal_led.tuck` blinking an LED; the final milestone is two stackless
tasks driving two LEDs independently, as in `stage5_stackless_blink.tuck`.

## API choice

A single compiler flag selects freestanding mode, mirroring Nim's own
`--os:standalone`:

- **`--freestanding`** (new). Implies `--concurrency:stackless`,
  `--actors:single`, `--frames:static`, and `--mm:none`. Passes `-d:freestanding`
  (Nim), `-DFREESTANDING` (D), and a freestanding build define (Odin) to the
  backends so runtime code selects embedded modules via `when defined(freestanding)`.
- **`--board:NAME`** (new). Selects a board package (memory map, registers,
  startup, linker script, QEMU machine). Defaults to host (no board). Example:
  `--board:lm3s6965evb`, `--board:bluepill`.
- Existing `--target:NAME` / `when TARGET == "..."` keeps working for
  conditional source; `--freestanding` is orthogonal (it is about the *runtime*,
  not source conditionals).

Integration pattern (Nim side):

```nim
when defined(freestanding):
  import tuck_rt_freestanding   # static alloc, no epoll
else:
  import tuck_rt                # OS allocator + reactor
```

The same `when` is applied in `tuck_sl.nim`, `tuck_coro.nim`, and the scheduler.
Tuck's own conditional compilation (`when TARGET == "freestanding":`) is used in
stdlib board packages so a driver can be written once against `platform.hal`.

## What is needed (points 1-6 + more)

### 1. Freestanding allocator (replaces `alloc`)

- **Problem:** `tuck_sl.nim:98` and `tuck_rt.nim` call `alloc` (malloc). With
  `--mm:none` there is no GC but `alloc` still resolves to libc malloc, which
  does not exist on bare metal.
- **Fix:** add new `compiler/tuck_rt_freestanding.nim` providing a static bump
  allocator (a fixed byte array + cursor) plus `alloc`/`dealloc` shims. Gate the
  OS allocator behind `when not defined(freestanding)`.
- **Ownership glue:** `rt.tuckDrop`/`rt.tuckCopy` walk types and free storage.
  For freestanding, frees of pool/slab-owned values must be no-ops or
  pool-releases; add a tenancy check so a value's storage is only freed if it
  came from the bump allocator, not a `pool`/`slab`.

### 2. Static frames (already built, must be implied)

- `--frames:static` places frames on stack/static storage; refuses programs
  whose frame count/size is not statically known, naming why. `--freestanding`
  implies it. No new code; just wiring.

### 3. Minimal scheduler (no epoll, no threads, no timers-as-OS)

- Replace the reactor in freestanding mode with a ready FIFO + `drive` loop only.
- Remove the offload pipe and thread pool.
- Timers become optional: if a board provides a SysTick hook, schedule on it;
  otherwise busy-wait (`platform.rtos` exposes a `sleep` that spins or WFI).
- `--actors:single` is implied, so no thread scheduling.

### 4. I/O primitives mapped to hardware

- `fdRead`/`fdWrite`/sleep become board HAL calls.
- Console output (`echo`/`printLine`) maps to semihosting on QEMU and UART on
  real hardware, via `rawoutput`.

### 5. Volatile register access (already works)

- `register` decls lower to `tuckVolatileLoad/Store` (Nim), `intrinsics.volatile_*`
  (Odin), D volatile. No OS needed. Board packages provide the register decls.

### 6. Startup, vector table, linker script

- Provide a board descriptor + template startup assembly and linker script in a
  new `boards/` directory.
- `tuck b --board:NAME` invokes the cross toolchain (arm-none-eabi-gcc) with
  the startup file and linker script, producing an ELF.

### 7. Panic / rawoutput

- Nim standalone requires `rawoutput` and `panic`. Provide `rawoutput` via
  semihosting (QEMU) or UART (board). Provide a panic handler that prints and
  halts (or resets).

### 8. Board packages in stdlib-project

- Add `stdlib-project/modules/platform/board/<name>.tuck` per chip implementing
  `platform.hal` groups (`OutputPin`, `InputPin`, `I2cBus`, …) as register
  writes, plus `platform.boot` regions.
- Driver code is written once against `platform.hal` and compiled per board.

### 9. Build system integration

- `tuck b --freestanding --board:lm3s6965evb` runs arm-none-eabi-gcc with the
  board's startup + linker script and emits an ELF.
- For Nim backend: use `--os:standalone --cpu:arm --mm:none` plus
  `--passL` for the linker script and startup objects.
- Document the QEMU invocation:
  `qemu-system-arm -M lm3s6965evb -semihosting-config enable=on,target=native -kernel out.elf`.

### 10. Testing

- Add new `tests/suites/freestanding.nim` that builds `bare_metal_led.tuck` with
  `--freestanding --board:lm3s6965evb` and runs under QEMU, checking semihosting
  output (or a memory-mapped success flag).
- Extend to `stage5_stackless_blink.tuck` once the scheduler is freestanding.

### 11. More I know about

- `str` (growable strings) need an allocator; on freestanding, either disable
  or back with a static buffer pool. Recommend disabling growable `str` on
  freestanding initially (use fixed `Array[N, u8]`).
- Interrupt safety: `[irq_safe, no_alloc, no_recursion]` is parsed and the stack
  budget is checked; enforcement on freestanding should be strict (compile error
  if violated).
- `platform.interrupt` is a simulation; real ISRs are installed by the board
  package and the compiler enforces what they may call.
- Stackless tasks with `on_full: wait` need the scheduler to park on a mailbox
  without an OS; the freestanding scheduler must support this (a simple wait
  queue per mailbox).

## Phased roadmap

| Phase | Work | Deliverable |
|---|---|---|
| A | Wire `--freestanding` flag; imply stackless/single/static/mm:none; pass defines to backends | Flag exists, host builds unaffected |
| B | Freestanding allocator in `tuck_rt` | `alloc` resolves to static bump on freestanding |
| C | Freestanding scheduler (ready FIFO, no reactor) | Task drive loop runs on host sim |
| D | `rawoutput`/`panic` via semihosting | Nim standalone links |
| E | Startup + linker script + `--board:` + arm-none-eabi-gcc invocation | ELF builds |
| F | Board package `lm3s6965evb` implementing `platform.hal` | Registers available to Tuck |
| G | QEMU test harness + suite | Automated bare-metal run |
| H | Port to Blue Pill (real hardware) | LED blinks on board |

## Open questions

- Should `--freestanding` be a top-level flag or a `--target:` value? Proposed
  both: `--freestanding` (runtime) + `--board:` (silicon). This keeps
  `--target:` for source conditionals.
- How to handle `str`? Recommend fixed buffers on freestanding; decide in Phase B.
- Whether to support actors at all on freestanding, or only tasks. Recommend
  tasks only initially; actors require a mailbox scheduler that can park.

## Risks

- Ownership glue freeing pool-owned values (double-free or corruption). Mitigate
  with tenancy checks in Phase B.
- `tuck_sl`/`tuck_rt` OS coupling may be deeper than `alloc`; audit in Phase B
  before committing to the bump allocator approach.
- Stack overflow on small SRAM (20 KB): `--frames:static` helps, but deep call
  chains still consume stack. Need stack budget enforcement (already parsed via
  `[stack: N]`; verify it is enforced, not just parsed).

## Files to touch (estimate)

- `tuck.nim` — add `--freestanding`, `--board:` flags.
- `compiler/tuck_rt.nim`, `compiler/tuck_sl.nim`, `compiler/tuck_coro.nim` —
  `when defined(freestanding)` gates.
- New files: new `compiler/tuck_rt_freestanding.nim` and new `compiler/tuck_scheduler_freestanding.nim`.
- New: `boards/` directory with startup + linker scripts.
- `stdlib-project/modules/platform/board/` — board packages.
- new `tests/suites/freestanding.nim` — QEMU harness.
- `docs/stackless-concurrency.md` — freestanding section.

---

# High-friction points and how others solved them

Research gathered 2026-11-19. Each subsection: the friction, how other systems
solved it, and the recommended Tuck approach.

## H1. Growable `str` (the hardest one)

**Friction.** Tuck's `str` is a growable, owned string. On freestanding there
is no malloc, and even with a static bump allocator, frees are permanent (bump
never reclaims), so repeated string growth leaks the whole heap.

**How others solved it.**

- Rust `no_std`: split into `core` (no alloc) and `alloc` (needs a global
  allocator). `core::str` and `&str` slices work without a heap; `String` needs
  `alloc`. Most embedded code uses `heapless::String<N>` — a fixed-capacity,
  inline buffer (no heap, no fragmentation, `push` returns `Err` when full) or
  `core::fmt::Write` into a fixed buffer. `nstr` is another no-alloc string
  crate. `flat_string::FlatString<N>` is const-generic and `no_std` by default.
- Arduino/Mbed: heaps exist but are discouraged; fixed buffers preferred.
- Embedded Rust consensus (from the embedded book): "avoid alloc in
  safety-critical or long-running systems; if you must alloc, allocate at
  startup and never free."

**Recommendation for Tuck.** Do not back `str` with a static bump allocator on
freestanding (it would leak). Instead:

- Phase B: disable growable `str` on freestanding (compile error or fallback to
  `Array[N, u8]`), matching Rust's `core::str` (slices only).
- Provide a fixed-capacity string type in `stdlib-project` (e.g.
  `platform.str.FixedStr[N]` or reuse `Array`) with `push` returning `?`/error
  when full, mirroring `heapless::String`.
- Formatting goes through `core::fmt::Write`-style into a caller-provided buffer,
  not into a growable `str`.
- If a user truly needs dynamic strings, allow opting into `alloc` mode
  (`--freestanding-alloc`) backed by a static heap (embedded-alloc style), with
  the documented caveat that frees are permanent or pooled. Default freestanding
  stays heapless.

## H2. Freestanding allocator

**Friction.** Need `alloc`/`dealloc` without libc.

**How others solved it.**

- Rust `embedded-alloc` (formerly `alloc-cortex-m`): a `#[global_allocator]`
  backed by a static byte array (`[MaybeUninit<u8>; N]`), initialized once at
  startup. Two strategies: LLFF (linked-list first-fit) and TLSF (two-level
  segregated fit). Requires a critical-section implementation.
- `linked-list-allocator`: simple, small code size.
- `slaballoc`: no-std, thread-safe fixed-size slab allocator (bitmap of slots).
- `the-slab`: SLUB-style slab allocator over a page allocator.
- Rust embedded book: "if you can avoid the heap, do; if you must, allocate at
  startup and never free."

**Recommendation for Tuck.** Two-tier, matching Tuck's existing `pool`/`slab`:

- Tier 0 (default freestanding): no heap at all. `pool` and `slab` already
  provide static, fixed-size storage. `alloc` is a compile error.
- Tier 1 (opt-in `--freestanding-alloc`): a static bump allocator (simplest,
  O(1), no frees) for startup-time allocations, OR a slab allocator for
  fixed-size objects. Do not use general-purpose first-fit on metal unless
  needed; document fragmentation risk.
- Critical sections: on single-core, disable interrupts (CPSID i) around alloc;
  Tuck's `platform.interrupt` / `beginCritical`/`endCritical` already model this.

## H3. Semihosting / `rawoutput` / panic

**Friction.** Nim standalone requires `rawoutput` and `panic`; bare metal has no
console.

**How others solved it.**

- ARM semihosting: a trap instruction (`BKPT 0xAB` / `SVC 0x123456`) asks the
  debugger/QEMU to do I/O. Newlib links with `--specs=rdimon.specs` and
  provides `_sbrk`/`_write` via semihosting. `cortex-m-semihosting` crate.
- On real hardware: UART output; `panic-halt` (hang) or `panic-probe` (RTT).
- Rust: `#[panic_handler]` is mandatory in `no_std` binaries.

**Recommendation for Tuck.** Provide `rawoutput` in `tuck_rt_freestanding.nim`:
- On QEMU (`--board:lm3s6965evb`): semihosting via `BKPT 0xAB` (ARMv7-M).
- On real boards: UART (board-provided `putc`).
- `panic`: print message via `rawoutput`, then halt (WFI loop) or reset.
- Gate with `when defined(qemu):` / board define.

## H4. Startup, vector table, linker script

**Friction.** Bare metal needs SP init, vector table, .data copy, .bss zero,
then main.

**How others solved it.**

- `cortex-m-rt`: provides the reset handler, vector table, and `#[entry]` macro;
  linker script (`memory.x`) defines FLASH/RAM regions.
- CMSIS: startup_*.s assembly + system_*.c.
- Rust embedded book: "runtime crates define the real entry point."

**Recommendation for Tuck.** Ship a `boards/` directory with per-board:
- `startup_<board>.s` (vector table + reset handler copying .data, zeroing .bss,
  calling `main`),
- `<board>.ld` linker script (FLASH/RAM from `platform.boot` regions),
- a board descriptor (Nim/Python) consumed by `tuck b --board:NAME`.
- Tuck's `main` becomes the entry point symbol (exported). `platform.boot`'s
  `Region` list can generate the linker script memory map.

## H5. Scheduler on bare metal

**Friction.** Stackless tasks need a ready queue and drive loop; OS provides
epoll/timers.

**How others solved it.**

- RTIC (Real-Time Interrupt-driven Concurrency): tasks are interrupt handlers;
  scheduling is priority-based with zero-cost context switches; no OS.
- Embassy: async/await on bare metal using hardware timers and interrupts; an
  executor per core.
- FreeRTOS/Zephyr: full OS (too heavy for small SRAM).
- For tiny systems: a single cooperative loop driving a FIFO of task frames,
  with `WFI` when idle; timers via SysTick interrupt setting a flag.

**Recommendation for Tuck.** Freestanding scheduler = ready FIFO + `drive` loop
only (no threads, no epoll). Timers are opt-in via a SysTick hook that enqueues
a "tick" task. Actors with `on_full: wait` park on a per-mailbox wait queue;
`raise` from an ISR (or a polled flag) wakes them. Keep it cooperative; no
preemption. This matches Tuck's existing stackless design (ruling: semantics
unchanged, only implementation).

## H6. Interrupt safety and critical sections

**Friction.** Shared state with ISRs; reentrancy.

**How others solved it.**

- RTIC: critical sections via `lock`; compile-time priority ceiling.
- Cortex-M: `CPSID i` / `CPSIE i` (disable/enable interrupts).
- Rust `critical-section` crate: portable API; on single-core, disable interrupts.
- Tuck already has `platform.interrupt` (simulated controller with
  `beginCritical`/`endCritical`/held delivery) and `[irq_safe, no_alloc,
  no_recursion]` markers with stack budget.

**Recommendation for Tuck.** On freestanding, `beginCritical` lowers to
`CPSID i` and `endCritical` to `CPSIE i` (plus flush held). `[irq_safe]` fns
must be checked to use only irq-safe operations (already parsed; verify
enforcement). Stack budget `[stack: N]` must be a hard error, not a warning.

## H7. Stack overflow protection

**Friction.** On Cortex-M, stack overflow silently corrupts `.data`/`.bss`.

**How others solved it.**

- `flip-link`: reverses RAM layout so the stack sits at the bottom of RAM; an
  overflow hits the RAM boundary and triggers a HardFault instead of silently
  corrupting data. Zero runtime cost.
- MPU-based stack guards (heavier).

**Recommendation for Tuck.** Use `flip-link` in the default linker invocation
for `--board:` builds (zero cost, huge debugging value). Document it.

## H8. Memory pools vs heap (already in Tuck)

- Tuck's `pool` (fixed array of slots, acquire/release by index+tenancy) and
  `slab`/`arena` already provide static, fragmentation-free storage. These are
  the right primitives for freestanding; the freestanding allocator (H2 tier 0)
  should be "no alloc" and rely on these.
- Guidance: prefer `pool`/`slab` on freestanding; enable `alloc` only when
  truly needed (protocol parsing, variable messages), with the caveat.

## Summary of recommended Tuck-specific decisions

1. `str` on freestanding: slices + fixed-capacity `FixedStr[N]`; growable `str`
   disabled by default, opt-in `--freestanding-alloc` for dynamic strings.
2. Default freestanding: no heap (tier 0). Opt-in heap via static array + bump or
   slab allocator (tier 1), with fragmentation documented.
3. `rawoutput`/`panic`: semihosting on QEMU, UART on real boards.
4. Startup via board-provided assembly + linker script; `platform.boot` regions
   can generate the memory map.
5. Scheduler: ready FIFO + drive loop; timers and I/O are board hooks; actors
   optional (tasks first).
6. Critical sections lower to CPSID/CPSIE; `[irq_safe]` and `[stack: N]`
   enforced strictly.
7. Use `flip-link` by default in board builds.
8. Prefer `pool`/`slab` over `alloc` on freestanding.

## Files to touch (estimate)

- `tuck.nim` — add `--freestanding`, `--board:` flags.
- `compiler/tuck_rt.nim`, `compiler/tuck_sl.nim`, `compiler/tuck_coro.nim` —
  `when defined(freestanding)` gates.
- New files: new `compiler/tuck_rt_freestanding.nim` and new `compiler/tuck_scheduler_freestanding.nim`.
- New: `boards/` directory with startup + linker scripts.
- `stdlib-project/modules/platform/board/` — board packages.
- `stdlib-project` — add `FixedStr` (or document `Array[N,u8]`).
- new `tests/suites/freestanding.nim` — QEMU harness.
- `docs/stackless-concurrency.md` — freestanding section.

## Note on saving location

This expanded plan is saved in `/home/kl/.opencode/plan/freestanding-baremetal.md`
(Plan mode restricts file writes to that directory). To place a copy in
`testing_experiment/`, switch agents (or copy the file) — I cannot write
outside the plan directory while in Plan mode.
