# Tuck on bare metal — the vision

Status: consolidated 2026-11-22. **This file and `ROADMAP.md` beside it replace**
`FREESTANDING-PLAN.md`, `EMBEDDED-DEBUGGING-VISION.md`,
`IMPLEMENTATION-GROUND.md` and `EXECUTION-PLAN.md` (now in `archive/`, kept
for their rationale and their recorded traps). Evidence for every "today"
claim below is in `REVIEW-2026-11-22.md`.

Trust order, as for the rest of Tuck: the compiler beats `tuck-spec.md`
beats this file. **This file proposes no syntax** (owner, 2026-11-22: syntax
needs its own design round, §2a). It states requirements, the layer each
fact belongs to, and the options; the spellings come later.

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
   A driver provides handlers; the application binds them to interrupt
   lines and priorities (§2a), so one driver serves many programs. Shared state, critical sections and the ISR→task hand-off are
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

## 2a. Reuse: libraries declare, applications bind

The owner's objection to the first draft (2026-11-22): a handler written as
"this fn is USART1's interrupt at priority 2", or a task written as "at most
4 of me", cannot be reused. The next application has the UART on USART2, a
different priority map and a different load. That is the C habit of baking
the board into the driver, and Tuck is not meant to be another C.

**The rule: a library states only what it needs, the application states
only what it chooses, and the compiler infers everything it can see.**

| Fact | Belongs to | Never in |
|---|---|---|
| "I handle a byte-received event", "I may run in interrupt context" | the driver (library) | — |
| register layout of a UART; which interrupt lines it has | the chip package (generated from SVD) | the driver |
| which instance (USART1 at `0x40013800`), which pins, which line number | the board package | the driver |
| which instance *this* program's console uses; priorities; queue sizes; caps on concurrency; deadlines; budgets | the application, in one place | the driver, the board |
| how many frames a spawn site needs; ceilings; stack depth; which vectors are used | the compiler, from the whole program | anyone's source, unless it cannot be inferred |

Consequences for the pillars below:

- **Interrupts.** A driver's handler is an ordinary fn that says it is safe
  in interrupt context (today's `[irq_safe]` restriction already says
  exactly this). *Which* vector it serves and at *what* priority is a
  binding the application makes. Priority-ceiling analysis runs after
  binding, over the whole program, so the driver stays priority-agnostic and
  the checker still proves the composed system.
- **Peripheral instances.** One layout type per peripheral kind, many
  instances. A driver is generic over the instance (a group bound, as
  `platform.hal` already does with `[B: I2cBus]`), and monomorphisation keeps
  it zero-cost. Today's `register NAME at ADDR` makes each instance a
  separate global (`USART1_SR`, `USART2_SR`), so a driver written against
  one cannot drive the other: that is a reuse gap in the existing language,
  not only in the plan. SVD already encodes the sharing (`derivedFrom`).
- **Concurrency counts.** Tuck sees the whole program, so most frame counts
  are inferable: N spawn sites, a spawn in a loop with a constant bound, a
  handler that spawns at most once per event with a bounded queue. Only
  where the count genuinely depends on run-time data does the compiler ask
  for a bound, and it asks the *application* (the owner of the spawn site
  or the wiring), never the task's declaration.
- **Budgets and deadlines.** A task's deadline is a property of the system
  it runs in, not of the task. `[stack: N]` likewise: a library may state a
  bound it guarantees, but the budget it must fit is the application's.

**Precedents Tuck already has**, so this extends the language rather than
bolting a configuration system on: groups (compile-time bounds,
monomorphised), board packages handing out configured handles
(`platform.hal`), the event registry (one application-wide declaration of
the whole event surface, spec Part 10), `pool` (application-level static
storage), and `when TARGET` (target selection without a preprocessor). A
hardware interrupt is an event in the application's event surface, and
that is now the **leading direction** (owner, 2026-11-22: "different worlds
but similar semantics"): drivers declare event sets, the application's
registry composes them and binds lines to them, and the same driver runs on
a host where a test raises the event. Worked out, with what the compiler
already does and the questions to rule, in **`DESIGN-interrupt-events.md`**.

**Interrupts are a stricter kind of event, and policies may not reach a
finished component's normal path.** Hosted events, the error policy, the
resource registry's overrides, `pending:` stub flags and build flags all let
a decision be made later or elsewhere; for an interrupt each of those is a
defect (an unacknowledged source re-fires forever; a handler added by an
importer runs in interrupt context; a shrunk queue drops bytes). The exact
rules, IRQ-1..9 and POL-1..6, are in `DESIGN-interrupt-events.md` §3a–§3b. The
criterion: *a policy may decide what happens when something goes wrong, only
within what the component declared it tolerates; it may never change what a
correct component does on its normal path; and interrupt context is
policy-free.*

**The reuse test**, the acceptance criterion for any syntax proposed for
interrupts, instances, counts, priorities or deadlines: *one unchanged UART
driver module compiles into two applications on two boards, with different
instances, interrupt lines, priorities and load, and the checker proves both
(ceilings, frame counts, budgets) without the driver naming any of it.* A
proposal that needs the driver edited fails the test.

**The design round** (roadmap item 1.0), before any of these spellings
land: write the reuse-test programs in pseudo-Tuck under two or three
competing designs, judge them on the test, on how much the application must
write in the common case (target: nothing that the compiler can infer), and
on how the error reads when the compiler cannot infer. Then rule.

## 3. The architecture

``text
  ┌──────────────────────────────── source ──────────────────────────────────┐
  │ drivers (libraries)   chip package (SVD)     board package   application │
  │  generic over kinds,   layouts, lines,        instances,      bindings:  │
  │  handlers, tasks       w1c facts              pins, regions   lines,     │
  │  (no instance, line,                          clocks, console priorities,│
  │   priority or count)                                          bounds     │
  └───────────────┬──────────────────────────────────────┬───────────────────┘
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
``

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
  static home for those frames, sized by **whole-program inference** where
  the count is knowable and by an **application-level bound** where it is
  not (§2a); never a count baked into the task, which would make it
  unreusable (Embassy's per-task `pool_size` is the anti-pattern here). The
  frame heap and its runtime "exhausted" PANIC then become a compile-time
  answer: a number in the budget, or an error naming the spawn site.
- **Budget at build.** Frames + pools + queues + the event ring + the stack
  (§4.5) are summed against the board's RAM, per region, and printed by
  `tuck build`. Over budget is an error naming the largest contributors.
- **Linker scripts are generated** from the board's regions, with a reserved,
  checked stack, aligned section ends, `.noinit` for the crash record, and
  `flip-link` layout (stack below `.bss`, so overflow faults instead of
  corrupting data).
- **No hidden RAM.** Today ~4.6 KB is spent before user code: a 2 KB heap
  (goes with static frame homes, §4.2), the 1 KB TLS block Nim's error flag drags in
  (goes with `-ftls-model=local-exec` or plain globals), and a 1.25 KB ring
  (stays, sized by the board).

### 4.3 Interrupts: declared needs, application bindings

Leading design: interrupts enter as registry events (`DESIGN-interrupt-events.md`).
Three facts, three owners (§2a):

1. **The chip package lists the interrupt lines** (generated from the SVD:
   name, number, which peripheral raises it).
2. **A driver provides handlers** as ordinary fns marked safe for interrupt
   context, written against a peripheral *kind*, not an instance.
3. **The application binds** each line it uses to a handler instance and a
   priority, once. The board build then generates the full vector table; an
   unbound line goes to a default handler whose FAULT line names it.

What the checker does with the composed program:

- **Priority ceilings, after binding.** With every handler's priority known
  and the call graph, Tuck can do what RTIC does with Rust macros, in the
  checker: compute each shared resource's ceiling, lower `critical:` to "raise
  BASEPRI to the ceiling" (zero-cost, deadlock-free, leaves higher-priority
  handlers running), and report a race only where preemption is actually
  possible. The same driver bound at different priorities gets different,
  correct lowerings in each application. On Cortex-M0 (no BASEPRI) the
  lowering falls back to PRIMASK.
- **The FromISR rule is a reachability rule.** A bound handler may only reach
  ISR-safe operations: posting to an ISR queue, register access, pure
  computation. `send` to an actor, allocation and waits are already refused
  (TK-EF05/07/11); the error names the ISR-safe alternative.
- **Today's `[irq]` marker** (an ISR root, written on the fn) is the
  single-application shortcut the stages use. It stays useful for small
  programs; the design round decides whether it remains as sugar for
  "bound here" or goes.

### 4.4 Waiting on hardware: the metal reactor

The stackless transform already turns every pause into "store the frame
where it waits, return to `drive`". On a hosted build "where it waits" is
the epoll table or the timer wheel. On metal it is:

- **Timers.** A SysTick (or low-power timer) interrupt advances a 64-bit
  monotonic clock and readies the frames whose deadline passed. `sleep`
  parks instead of spinning. Tick-less mode (program the next deadline) is a
  later optimisation, needed for low power.
- **ISR queues.** In the events design these are the deferred delivery of a
  hardware-raised event: a typed, fixed-capacity, single-producer queue an ISR posts
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
  stage and per handler, reported against the static score. Then periods and
  deadlines, stated by the application for the tasks and handlers it runs
  (not inside reusable code, §2a), give per-task utilisation and the longest
  interval with interrupts masked. Report first; gate on opt-in.

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

- **Register blocks as types** (new, §2a): one layout per peripheral kind,
  instances as values at addresses, drivers generic over the instance. Today
  each instance is a separate global, which defeats reuse.
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
- **Source debugging** (exists under QEMU via `gdb-run.sh`): the same
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

Two kinds. **Design questions** go through the design round (§2a) and are
judged by the reuse test; no spelling is recommended here. **Plumbing
decisions** are technical and have a recommendation.

### Design questions (no syntax until the design round)

| # | Question | Requirements it must meet |
|---|---|---|
| D1 | How does an application bind interrupt lines to handlers and priorities? | driver names no line or priority; one place per application; ceilings computed after binding; an unbound or doubly-bound line is a compile error. **RULED 2026-11-22:** `bind LINE -> module.fn [priority: N, queue: N]` in the application (`DESIGN-interrupt-events.md` §5) |
| D2 | Where do spawned tasks' frames live under `--frames:static`? | inferred when the count is knowable; when not, the bound is stated by the application at the spawn site's owner, never in the task; the error names the site |
| D3 | How are write-1-to-clear and write-only-mask fields described? | a chip-package fact, generated from SVD `modifiedWriteValues`; codegen never read-modify-writes such a register |
| D8 | How are periods and deadlines stated? | by the application for the tasks it runs; a library may state a guarantee (a bound it meets), not a requirement |
| D9 | Fixed-point (Q notation) | a numeric type surface consistent with the 2026-08-25 numeric rulings; independent lane |
| D12 | How do register blocks become instance-generic? | one layout type per kind, instances at addresses, zero-cost monomorphised drivers; SVD `derivedFrom` maps onto it; today's `register NAME at ADDR` keeps working |
| D13 | Is a hardware interrupt an event in the application's registry (Part 10), a new wiring declaration, or a board-package concern? | answered first: D1, D2 and D8 follow from it. **RULED 2026-11-22: events.** A driver owns a registry per module, marks each event `[stream]`, `[signal]` or `[latest]` and fixes its overflow; one `[irq]` fn decides the cause with a `decision` table and raises; reactions are ordinary `on` handlers in task context (`DESIGN-interrupt-events.md` §5, §7) |

### Plumbing decisions (recommendation given)

| # | Decision | Recommendation |
|---|---|---|
| D4 | `int` width on 32-bit targets | native word (as ruled); the host sim builds 32-bit for a metal board |
| D5 | Output transport + log format | console channel per board (semihosting/RTT/UART); deferred-format records decoded from the ELF |
| D6 | Peripheral-level simulator | adopt Renode as rung 3, keep QEMU for ISA/faults |
| D7 | Backends on metal | Nim first, then D (LDC betterC), then Odin (`freestanding_arm32`), each against the runtime contract; gaps tracked |
| D10 | picolibc in the repo | **done 2026-11-22**: pinned release URL + SHA-256, fetched and cached by `boards/picolibc/build.sh` (byte-identical to the vendored tree it replaced) |
| D11 | Where the code lives after merge | **done 2026-11-22**: `boards/`, `tools/metal/`, `tools/svd2tuck/`, `tests/metal/`, `docs/bare-metal/`; `testing_experiment/` is gone |
