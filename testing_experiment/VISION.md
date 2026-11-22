# Tuck on bare metal — the vision

Status: consolidated 2026-11-22. **This file and `ROADMAP.md` beside it replace**
`FREESTANDING-PLAN.md`, `EMBEDDED-DEBUGGING-VISION.md`,
`IMPLEMENTATION-GROUND.md` and `EXECUTION-PLAN.md` (now in `archive/`, kept
for their rationale and their recorded traps). Evidence for every "today"
claim below is in `REVIEW-2026-11-22.md`.

Trust order, as for the rest of Tuck: the compiler beats `tuck-spec.md`
beats this file. Where this file proposes syntax, it is a proposal (marked
`text`, never `tuck`) until the owner rules on it.

---

## 1. What "first-class" means

Bare metal is first-class when **a firmware engineer can write, check, run,
debug and ship a real interrupt-driven program in Tuck without leaving Tuck's
tools, on all three backends, and the compiler proves more about it than a C
toolchain can.** Concretely, five promises:

1. **Same language.** The program that runs on a Cortex-M is ordinary Tuck:
   the same values, effects, tasks, actors, `match`, errors. No "embedded
   dialect", no second standard library with different semantics. What does
   not fit a target is refused at compile time with a reason, never silently
   degraded.
2. **Static by default, proven at build.** No heap unless asked. Every frame,
   task, queue, stack and buffer has a size the compiler knows, and
   `tuck build` prints the RAM and flash budget and fails when the board
   cannot hold it. (`--frames:static` already proves the frame half today.)
3. **Interrupts are part of the language, and races are compile errors.**
   An interrupt handler is a declared thing bound to a vector with a
   priority. Shared state, critical sections and the ISR→task hand-off are
   checked like ownership is checked: through the call graph, by declaration
   id, with both sides of a race named.
4. **Waiting on hardware is just `[io]`.** A task that waits for a timer, a
   UART byte or a DMA completion parks its frame exactly as a hosted task
   parks on epoll. The CPU sleeps (`WFI`) when nothing is ready. The spec's
   open hole ("waiting on hardware without a reactor is not designed yet",
   §9) is closed by a *metal reactor*, not by new concurrency syntax.
5. **Every failure is loud, located and reproducible.** A fault, a failed
   check or an exhausted budget names the Tuck line. The same binary runs
   deterministically in simulation. A test that cannot fail is treated as a
   bug in the test. (The review pass made this true for the QEMU loop;
   §6 makes it true everywhere.)

The measure of success is not a demo. It is **one real firmware of 5–10k
lines** (owner direction 2026-10-10, #107) — say a sensor node: UART console,
I²C sensor, timer-driven sampling, a watchdog, low-power idle — built on the
Blue Pill and an RP2040, debugged with Tuck's own tools.

## 2. Principles (how decisions get made)

- **Decide once, print three times.** Every metal behaviour (vector table,
  critical sections, parking, the reactor) is decided in shared lowering and
  a written **metal runtime contract**; Nim, Odin and D only print it. Odin
  already has `-target:freestanding_arm32`; LDC's `-betterC` targets
  `thumbv7m-none-eabi`. Metal is Nim-first today, and every gap is tracked,
  not implied (owner rule: backends in tandem).
- **Reuse the checked machinery.** Effects, call edges (`calleeDecl`), the
  stackless colouring, `--frames:static`, `pool`, `register`, `when TARGET`
  already exist. Metal features extend them. A parallel "embedded checker"
  is a smell.
- **Report, then gate.** A new analysis ships as a report with a stable
  machine format (JSON/SARIF) first, and becomes an error once its
  false-positive rate is known (`--isr-check:error` is the pattern).
- **Industry vocabulary, checked.** Tuck does not invent embedded practice;
  it turns the trodden path into rules: tiny ISRs, top-half/bottom-half,
  FromISR APIs, single-writer tables, priority ceilings, watchdog + safe
  state, static allocation. Formats are the ones the toolchain already
  reads: CMSIS-SVD, device tree, DWARF, SARIF, CTF, JUnit, GDB RSP.
- **Evidence ladder.** A claim is only as strong as the rung that tested it:
  host sim (logic) < QEMU (ISA, faults, exceptions) < Renode (peripheral
  models) < hardware. Each claim in the roadmap names its rung.

## 3. The architecture

```text
  ┌──────────────────────────── source ────────────────────────────┐
  │ program.tuck        board module (generated + overlay)         │
  │  tasks, actors,      chip: registers, interrupts (from SVD)    │
  │  [irq: X] handlers   memory regions, clocks, console, pins     │
  └───────────────┬───────────────────────────────┬────────────────┘
                  ▼                               ▼
        CHECK (shared, target-aware)       BOARD BUILD (shared)
        effects + ISR discipline +         vector table, linker
        priority ceilings + frames:static  script, startup, budget
                  │                               │
                  ▼                               │
        LOWERING (shared): stackless frames,      │
        critical → ceiling, waits → park points   │
                  │                               │
        ┌─────────┼─────────┐                     │
        ▼         ▼         ▼                     │
      Nim       Odin        D   ← each prints; each implements the
        │         │         │     METAL RUNTIME CONTRACT (§4.6)
        └─────────┴────┬────┘                     │
                       ▼                          ▼
                 ELF + DWARF + string table + budget report
                       │
     ┌─────────────────┼──────────────────────┬───────────────┐
     ▼                 ▼                      ▼               ▼
  host sim          QEMU                   Renode          probe
  (logic, 3 BE)  (ISA, faults, IRQs)  (peripherals, CI)  (flash, RTT)
     └──── one log/trace stream, decoded by `tuck` from the ELF ────┘
```

## 4. The pillars

### 4.1 Target model: boards, chips, profiles

Today a metal build is a shell script passing `--nim:"--os:standalone …"`,
a hard-coded linker script per board, and a startup file named after one
board but shared by two. That is the right prototype and the wrong product.

- **A board is a Tuck module** plus a small descriptor: chip (from SVD), memory
  regions (`platform.boot`), clock config, console transport, pin roles,
  QEMU/Renode machine name. `tuck build --board:bluepill FILE` does the rest:
  picks the runtime profile, generates the vector table and linker script,
  links, and prints the budget. `--target:` (source conditionals) is set
  from the board, so `when TARGET == "stm32f1":` works without a flag.
- **The metal profile is one switch**, `--freestanding` or implied by
  `--board:`: stackless, `--frames:static`, `--actors:single`, no reactor,
  no threads, `-Os` with section GC. Today these are four separate flags
  and the heap is still on.
- **Word size is part of the target.** Bare `int` is "the native word"
  (ruling 2026-08-25), so it is 32 bits on a Cortex-M. A host simulation on a
  64-bit host therefore cannot see a 32-bit overflow. The host sim for a
  metal board must build for a 32-bit host (`--cpu:i386 -m32` and the Odin/D
  equivalents), or the profile must say why it cannot. (The event ring's
  `int` head was exactly this bug.)

### 4.2 Memory: static, sized, reported

- **Frames.** `--frames:static` is the metal default. It already refuses a
  spawned-not-awaited task with a file:line reason. The missing piece is a
  home for those frames: **declared task instances**, a fixed count per task
  (Embassy's `pool_size`). The frame heap and its runtime "exhausted" PANIC
  then become a compile error.
- **Budget at build.** Frames + pools + queues + the event ring + the stack
  (§4.5) are summed against the board's RAM, per region, and printed by
  `tuck build`. Over budget is an error naming the largest contributors.
- **Linker scripts are generated** from the board's regions, with a reserved,
  checked stack, aligned section ends, `.noinit` for the crash record, and
  `flip-link` layout (stack below `.bss`, so overflow faults instead of
  corrupting data).
- **No hidden RAM.** Today ~4.6 KB is spent before user code: a 2 KB heap
  (goes with task instances), the 1 KB TLS block Nim's error flag drags in
  (goes with `-ftls-model=local-exec` or plain globals), and a 1.25 KB ring
  (stays, sized by the board).

### 4.3 Interrupts as declarations

```text
# PROPOSAL — not yet Tuck. Names come from the board's SVD interrupt list.
fn onUartRx() [irq: USART1, priority: 2]:
  let b = UART1_DR.DATA
  {byte: b} rxQueue.post
```

- `svd2tuck` emits the chip's interrupt names and numbers; `[irq: NAME]`
  binds a fn to that vector; the board build generates the full table. An
  unbound vector goes to a default handler whose FAULT line names it.
- **Priorities make the race analysis exact.** With a priority per handler
  and the call graph, Tuck can do what RTIC does with Rust macros, but in the
  checker: compute each shared resource's **priority ceiling**, lower
  `critical:` to "raise BASEPRI to the ceiling" (zero-cost, deadlock-free,
  leaves higher-priority handlers running), and report a race only where
  preemption is actually possible. The two-handler caveat in today's audit
  disappears, and an ISR no longer needs a needless `critical:` around its
  own access. On Cortex-M0 (no BASEPRI) the same lowering falls back to
  PRIMASK, so it is portable.
- **The FromISR rule is a type rule.** An `[irq]` fn may only reach
  ISR-safe operations: posting to an ISR queue, reading/writing registers,
  pure computation. `send` to an actor, allocation and waits are already
  refused (TK-EF05/07/11); that stays, and the error names the ISR-safe
  alternative.

### 4.4 Waiting on hardware: the metal reactor

The stackless transform already turns every pause into "store the frame
where it waits, return to `drive`". On a hosted build "where it waits" is
the epoll table or the timer wheel. On metal it is:

- **Timers.** A SysTick (or low-power timer) interrupt advances a 64-bit
  monotonic clock and readies the frames whose deadline passed. `sleep`
  parks instead of spinning. Tick-less mode (program the next deadline) is a
  later optimisation, needed for low power.
- **ISR queues.** A typed, fixed-capacity, single-producer queue an ISR posts
  to and a task awaits; the generalisation of today's one-word
  `tuckIsrPost`/`Take` slot, with overruns counted, never hidden.
- **`on select`** waits on several of the above, unchanged in meaning.
- **Idle.** When the ready list is empty the driver executes `WFI` with the
  race-free sequence (mask, re-check the ready list, `WFI`, unmask), so a
  wake-up between the check and the sleep is never lost. Today it spins.
- **Polled externs stay legal.** An `[io]` extern that completes before
  returning (a polled register read) runs inline, as now; an extern that
  must wait is declared against a wait source, so nothing on metal ever
  needs a helper stack.

### 4.5 Proven budgets: stack and time

- **Stack.** With stackless frames, the C stack holds only the running stage
  and the ISR nesting. Worst case = deepest stage path + the sum, over
  priority levels, of each level's deepest handler. The numbers should come
  from the compiled code (`-fstack-usage`) joined to Tuck's call graph, not
  from an AST guess. `[stack: N]` then becomes a hard error.
- **Time.** Static cycle scores on unoptimised code are not useful. Measure:
  instruction counts under QEMU `-icount`, `DWT.CYCCNT` on hardware, per
  stage and per handler, reported against the static score. Then
  `[period:, deadline:]` (owner decision) give per-task utilisation and
  the longest interval with interrupts masked. Report first; gate on opt-in.

### 4.6 The metal runtime contract

A short written API every backend implements, specified once and tested by
one suite on all three:

| Area | Calls |
|---|---|
| Masking | `criticalEnter() -> state`, `criticalExit(state)`, `raiseCeiling(p) -> state` |
| Scheduling | `ready(frame)`, `park(frame, source)`, `wake(source)`, `idle()` |
| Time | `now() -> u64`, `armTimer(deadline)` |
| Hand-off | `isrPost(queue, word)`, `isrTake(queue)`, `overruns(queue)` |
| Output | `consoleWrite(bytes)`, `logRecord(id, args)` |
| Failure | `fatal(msg)` (traps, LR = caller), `boardExit(rc)` |

The board provides the bottom half (`tuck_fatal`, `tuck_board_exit`,
console, timer); the review pass already introduced the first two.

### 4.7 Peripherals as types

- **Registers** (exist): typed fields, read/write permissions, volatile.
  Missing: **write-1-to-clear and write-only-mask fields**. Today a field
  write reads, modifies and writes the whole register, which clears every
  pending flag in a status register. svd2tuck must stop dropping
  `modifiedWriteValues`, and codegen must never read-modify-write such a
  register.
- **Ownership.** A peripheral is a singleton value obtained once; two drivers
  claiming the same pin or peripheral is a compile error. Sequencing (clock
  enabled before use, pin configured before write) uses the existing sealed
  `transitions:` construct rather than a new typestate system.
- **DMA.** A buffer handed to a transfer is moved into it and returned on
  completion. Tuck's ownership rules already express this if a transfer is a
  value that owns its buffer.
- **Clock tree** as a declaration: frequencies computed, peripheral maxima
  checked, register writes generated. **Vendor C** stays reachable through
  `extern [c]`: teams will call STM32Cube or pico-sdk, and that has to be a
  first-class path, not an escape hatch.

### 4.8 Observability on real transports

- **One stream, decoded from the ELF.** Console text, deferred-format log
  records (the format string stays in the ELF, the device sends an id and
  the arguments, as with defmt) and event-ring records travel the same
  channel. The channel is a board choice: semihosting under QEMU, RTT through
  a probe, or UART. `tuck log` / `tuck trace` decode it to text, JSON and
  CTF, with timestamps from the monotonic clock. This resolves the old
  "egress: semihosting vs ELF note" question: an ELF note cannot carry data
  captured at run time, so egress is the console channel, and a crash
  snapshot lives in `.noinit` RAM and is reported on the next boot.
- **Faults** (exist, and good): decoded CFSR/HFSR, the Tuck line via DWARF,
  SARIF output. Next: a PSP-aware handler, and "explain my crash" that joins
  the fault with the last ring records (which task, which wait, which queue).
- **Source debugging** (exists under QEMU via `gdb-loop.sh`): the same
  recipe through probe-rs or OpenOCD on hardware.

### 4.9 Simulation and test

| Rung | Tool | What it proves | Status |
|---|---|---|---|
| 0 | `tuck ch` | types, effects, ISR rules, frames:static, budgets | partly |
| 1 | host sim (`tuck sim --host`), 32-bit | logic, scheduler, 3-backend parity | 3 backends, 64-bit only |
| 2 | QEMU (`tuck sim`) | Thumb code, faults, exit codes, SysTick/NVIC, gdb | yes (no real IRQ yet) |
| 3 | Renode | peripheral models (STM32 GPIO, UART, timers), scripted inputs, CI | not started |
| 4 | hardware + probe | real timing, electrical reality | not started |

Fault injection comes from **outside** the program: drop or duplicate a real
interrupt, flip a register through the gdbstub, exhaust a pool, stall a
clock. Today's `faultIsrDrop()` flag is read by the program itself, so it can
only find bugs the author wrote a branch for. Results go out as JUnit XML.

### 4.10 Safety features

Watchdog + `safeState` as declarations (the compiler checks each critical task
feeds it, and generates the feed), MPU regions from `platform.boot`, a stack
guard, power-state effects (what can wake from `stop`, clocks restored after
wake). These are what make the language "fearless" rather than merely
convenient, and they all sit on §4.3–§4.5.

## 5. What Tuck has that C and Rust do not

Worth stating, because it decides what to build first:

- **The whole program is visible to one checker** with call edges by id,
  declared effects and no recursion by default, so priority ceilings, stack
  bounds and ISR reachability are checker passes, not macro tricks (RTIC) or
  external tools (C static analysers).
- **Stackless frames make concurrency's RAM a compile-time number.** Embassy
  gets this from Rust futures; Tuck gets it from its own transform, and can
  print it.
- **Value semantics + ownership** make DMA buffers and ISR hand-offs
  expressible as moves.
- **Three backends** let a scheduler bug show up as a cross-backend
  difference in the host sim before any hardware is involved.

## 6. Non-goals (revisit, don't calcify)

- A general RTOS. Tasks + actors + the metal reactor + priorities are the
  model; wrapping FreeRTOS would bring back the races we are removing.
  (Interop with an RTOS-based vendor SDK through `extern [c]` is fine.)
- A GUI IDE. One CLI plus editor integration.
- Hand-written packages for 100 MCUs. SVD + overlay, plus a hand-written
  board module per supported board.
- Preemptive tasks. Preemption is what interrupts are for; tasks stay
  cooperative, which keeps their state lock-free.
- WCET as a hard gate on day one.

## 7. Decisions the owner needs to make

Each has a recommendation; none blocks Phase 0–1 of the roadmap.

| # | Decision | Recommendation |
|---|---|---|
| D1 | Interrupt binding spelling | `[irq: NAME, priority: N]` on a fn; names from the board's SVD |
| D2 | Static homes for spawned tasks | a per-task instance count, e.g. `task t(...) [instances: 4]` |
| D3 | Write-1-to-clear / write-only fields | a field attribute (`[w1c]`, `[write_only]`) that forbids read-modify-write |
| D4 | `int` width on 32-bit targets | native word (as ruled); host sim builds 32-bit for a metal board |
| D5 | Output transport + log format | console channel per board (semihosting/RTT/UART); deferred-format records decoded from the ELF |
| D6 | Peripheral-level simulator | adopt Renode as rung 3, keep QEMU for ISA/faults |
| D7 | Backends on metal | Nim first, then D (LDC betterC), then Odin (`freestanding_arm32`), each against the runtime contract; gaps tracked |
| D8 | `[period:, deadline:]` spelling | effect-position attributes on `task` and `[irq]` fns, report-only first |
| D9 | Fixed-point (Q notation) | a distinct type `Q[i, f]` with range checks at construction; independent lane |
| D10 | picolibc in the repo | replace the 4,193 vendored files with a pinned tarball URL + SHA-256, fetched and cached by `build-picolibc.sh` |
| D11 | Where the code lives after merge | `boards/`, `tools/metal/`, `tests/metal/` at top level; `testing_experiment/` retires |
