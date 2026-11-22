> **ARCHIVED 2026-11-22.** Superseded by `../VISION.md` (what and why) and
> `../ROADMAP.md` (what next). Kept for its rationale, its recorded traps and
> its observed QEMU results; do not plan from it. Where it disagrees with the
> two new files, they win.

# Embedded debugging, reimagined: prevent, report, observe, reproduce

Status: design proposal (2026-11-19). Companion to `FREESTANDING-PLAN.md`
(the mechanics of booting Tuck on bare metal). This document is about the
*product question*: when an MCU program misbehaves, how do we make Tuck the
best tool for finding out why — ideally by making the bug impossible.

## 1. The problem: the debugging ladder and why it costs days

When firmware misbehaves, a developer climbs a ladder of options. Each rung is
more expensive and less available than the one below it:

| Rung | Tool | What it gives | Cost / problem |
|---|---|---|---|
| 1 | Reason about the code | — | Cheapest, most fallible |
| 2 | `printf` / semihosting / SWO / RTT | Text at points in time | Intrusive; **changes timing** (Heisenbugs); needs a working UART; says nothing about state before a crash |
| 3 | JTAG/SWD + GDB | Halt, step, inspect registers/memory | Stopping the core destroys real-time behaviour; 2–8 HW breakpoints; can't see what happened *before* the halt; attaching can mask the bug |
| 4 | Trace: ITM/SWO, DWT watchpoints, ETM | Non-intrusive, timestamped, **look backwards in time** | Needs a probe + trace pin; expensive tools; small on-chip buffers; ETM not on every chip |
| 5 | Logic analyzer / oscilloscope | What the pins *actually* did | External, expensive, no software context |
| 6 | Post-mortem HardFault decode | Stacked PC/LR/CFSR | Hand-decoded today |
| 7 | Static analysis / compiler checks | Caught before hardware | Cheapest by far — but C tooling is weak |
| 8 | Simulation (QEMU / Renode) | Deterministic, no hardware | Limited timing / hardware fidelity |

**The insight that drives this plan:** almost all debugging effort is spent
climbing a ladder whose upper rungs are expensive and scarce. The cheapest fix
is to make the bug impossible (rung 7). The second cheapest is a built-in
recorder that works without a probe (a software version of rung 4). Tuck owns
the entire pipeline — language, checker, lowering, codegen, runtime — so it can
move both of those *into the language* instead of leaving them as external
tools the developer must find, buy, and hand-glue.

This is not a rejection of hardware tools: electrical/signal-integrity bugs,
analog behaviour, and silicon errata still need scopes and logic analyzers. The
claim is narrower: the **software-side** bug classes — registers, timing, races
— are largely preventable or reportable before you ever reach for a probe.

## 2. What Tuck already prevents (do not rebuild this)

Tuck already has a strong prevention layer:

- **Value semantics / no references** → no dangling pointers, no aliasing surprises.
- **Ownership + last-use analysis** → no leaks, no double frees.
- **Declared effects `[io]`, `[io: net]`** → no hidden side effects; you know which code touches hardware.
- **Exhaustive `match` / decision tables / sealed `transitions:`** → no forgotten cases, no illegal state changes.
- **Invariants** → values can't exist in a ruled-out state.
- **`register` decls with `[read]`/`[write]`** → compile error on writing a read-only bit, reading a write-only bit; masked/shifted access (no wrong-bit RMW).
- **`[irq_safe, no_alloc, no_recursion]` + stack budget** → parsed, partly enforced.
- **`pool` / `slab` / no-heap default** → fragmentation-free, deterministic memory.
- **No unhandled `!T` / `T?`** → no silent errors.
- **Actors as the concurrency unit** → no shared mutable state between tasks.
- **Explicit `on_full: wait | drop | assert`** → mailbox overflow is a decision, not an accident.

This is already ahead of embedded C and competitive with embedded Rust. The
gaps are exactly the ones the owner named — **registers, timing, races** — plus
ISRs and crash forensics.

## 3. The four-layer strategy

```
 Layer 4  REPRODUCE   same binary in QEMU with virtual time; deterministic replay
 Layer 3  OBSERVE     built-in event ring + crash decoder (software ETM)
 Layer 2  REPORT      tuck audit / tuck timing: stack, WCET, utilization, register matrix
 Layer 1  PREVENT     register typestate + SVD, ISR discipline, single-writer MMIO, stack gate
           ^
      everything below is static and zero-cost; everything above is built in
```

### Layer 1 — PREVENT (compile errors)

**1a. Registers from SVD + typestate.**
The state of the art is Rust's `svd2rust` PAC + `embedded-hal` typestate: pins
must be configured before use; you can't `set_high` an input pin; peripherals
are singletons via `take()`. But research (`Interfacing with Hardware
Peripherals in Rust`, 2024; Embedded Rust Book "Static Guarantees") names the
remaining holes: PACs **don't enforce peripheral sequencing**, code can still
misuse clocks/pin-muxing/interrupts/DMA, and **SVD files contain vendor
mistakes**.

Tuck can do better because `transitions:` is already a first-class construct.
Make a peripheral a sealed state machine and let the checker enforce it:

```tuck
type UartState:
  | Unconfigured({})
  | Configured({baud: int})
  | Active({baud: int})

  transitions:
    Unconfigured -> Configured
    Configured   -> Active

# A member `fn write({self: Self, bytes: Seq[u8]}, ...)` is available only on
# UartState.Active; calling it on Unconfigured is a compile error, exactly like
# today's sealed state machines. The group/type-state spelling is finalised in
# step 1 of IMPLEMENTATION-GROUND.md.
```

Compiler errors for: writing reserved bits; using a peripheral before its
clock is enabled; two drivers claiming the same pin/peripheral; reading a
write-only field (already). A `tuck svd chip.svd` importer generates the
`register` decls + typestate + singleton ownership, with a **Tuck overlay** for
vendor corrections (mirrors the `platform.hal` group pattern already in
`stdlib-project/`).

**1b. ISR discipline — the biggest race hole.**
Actors and stackless tasks have value semantics, so there is no shared mutable
state between them. An ISR breaks that model: it can touch anything. Today
`platform.interrupt` *models* critical sections as values (`beginCritical` /
`endCritical`, held delivery) but the compiler does not enforce that shared
accesses are actually inside one.

Rule to enforce statically: state shared with an ISR must live in an explicit
`isrShared` slot and may be accessed **only** inside `beginCritical` /
`endCritical`. This is embedded Rust's `Mutex<RefCell<_>>` pattern, but checked
rather than conventional. A field touched by both an `[irq]` handler and normal
code outside a critical section → compile error naming both sites.

**1c. Single-writer MMIO.**
Two concurrent contexts (tasks, actors, an ISR) writing the same register
field is nondeterministic. With call edges and the concurrency analysis already
in the compiler, detect two writers to one field that aren't ordered by a
happens-before relation → compile error. Also covers DMA: a buffer handed to a
peripheral must be statically owned for the transfer's lifetime (Tuck's
ownership rules already do this if the transfer is modeled as a borrow).

**1d. Stack budget as a hard error.**
`[stack: N]` is parsed today; compute worst-case stack through the call graph
(no recursion under `[no_recursion]`) and refuse to build when exceeded. Pair
with `flip-link` (reverse RAM layout so overflow hits a guard and HardFaults
instead of silently corrupting `.data`/`.bss`) — already in `FREESTANDING-PLAN.md`.

### Layer 2 — REPORT (compile-time, zero runtime cost)

A new command family, `tuck audit FILE` / `tuck timing FILE`, printing:

- worst-case stack per function and the call path that produces it;
- conservative **WCET bound** per task / ISR;
- **task utilization**: sum of `WCET / period` against 100%, with margin;
- longest interrupt-disabled interval (critical-section nesting);
- a **register access matrix**: which fn/task/ISR reads or writes which field;
- unconfigured-peripheral and missing-effect warnings.

Why WCET is tractable here: bounded loops (`for`), no dynamic allocation by
default, no recursion by default, value semantics, declared effects. C WCET is
hard because the analyzer can't prove loop bounds or aliasing; Tuck already has
both facts. Ship the bounds as a **report first** (conservative estimates
produce false positives), then allow per-declaration opt-in gating:
`task t(...) [period: 1ms, deadline: 200us]`.

This turns "three days with a logic analyzer" into "one line of `tuck timing`".

### Layer 3 — OBSERVE (built-in, near-zero cost; software ETM)

When static checks can't catch it, give the developer a recorder that needs no
probe and doesn't perturb timing:

- **Event ring buffer**: a fixed-size `pool`-backed ring in RAM. Compiler
  instruments task switches, ISR entry/exit, every `[io]` call, mailbox-full
  events — a timestamped word write each, no printf on the critical path.
  Dump post-mortem over SWD/semihosting. This is the software analogue of ARM
  ITM/ETM "look backwards in time", minus the probe. The existing compiler
  nodes (`tuckSlReady`, stage fns, `exkSelect`) are ready-made instrumentation
  points.
- **Compiler-generated HardFault handler**: decode stacked PC/LR/xPSR/CFSR.
- **`tuck decode-crash dump.bin`**: map PC/LR back to Tuck source lines using
  debug info the compiler already controls. Today this is a manual, dreaded
  exercise; with full pipeline ownership it's a one-command decoder.

Key property: the recorder is in the runtime and the decoder is in the
compiler, so they share one source-level model. No hand-glued tools.

### Layer 4 — REPRODUCE (deterministic simulation)

Run the **same binary** under QEMU with virtual time. Stackless frames make the
scheduler deterministic (no minicoro stacks, no OS threads), so timing and race
bugs become replayable: same input → same event trace, every time. This is what
the current `testing_experiment/` rig begins to demonstrate; it's the foundation
the other layers sit on for validation.

## 4. Relationship to the current experiment

`FREESTANDING-PLAN.md` + `freestanding-loop.sh` are Layer 4's foundation and
the enabler for everything else: without a working freestanding toolchain no
built-in runtime tool runs on metal. The blocker found there — Nim's `memset`
coming from ARM-mode newlib on Thumb-only Cortex-M — is fixed by **vendored
picolibc**, which is therefore step 1 of the execution plan below, not a detour.

## 5. Execution plan (ordered)

| Step | Work | Exit criterion |
|---|---|---|
| 0 | Vendor a Thumb picolibc; replace newlib; full vector table + fault handlers | `stage9`/`stage10` (tasks) run to completion under QEMU |
| 1 | `tuck svd` importer: `register` decls + typestate + singleton ownership; Tuck overlay for corrections | A board package generated from an SVD checks the existing LED/register examples |
| 2 | ISR discipline + single-writer MMIO checks in the existing ownership/effect passes | `bugOpen` pins for an ISR race and a double-writer; checker refuses both |
| 3 | Stack-budget hard error via call-graph worst case; `flip-link` default | Exceeding `[stack: N]` is a compile error; overflow HardFaults |
| 4 | `tuck audit` / `tuck timing` reports (stack, WCET, utilization, register matrix) | Reports produced for every example; a task exceeding its declared deadline is flagged |
| 5 | Event ring + compiler-generated HardFault handler + `tuck decode-crash` | A deliberate fault in QEMU yields a decoded source-line crash report |
| 6 | Virtual-time deterministic replay in the QEMU loop | Same input twice → byte-identical event trace |

Steps 1–3 are static (zero runtime cost, highest bug-class payoff). Step 0 is
the gate for everything that runs on metal. Steps 4–6 turn the reports and
observability into a built-in developer experience.

## 6. Two decisions I want the owner's take on

1. **SVD-generated vs. hand-written board packages.** SVD gives coverage but
   imports vendor mistakes; hand-written is trustworthy but doesn't scale to
   100+ MCUs. Recommendation: SVD-generated with a Tuck overlay for corrections,
   mirroring the `platform.hal` group approach already in `stdlib-project/`.
2. **WCET/stack as report vs. hard gate.** Recommendation: ship as a report
   first (conservative bounds → false positives), then gate per-declaration via
   opt-in attributes like `[deadline: 200us]`.

## 7. Risks

- Typestate can be verbose; keep sealed transitions terse and lean on the
  existing `transitions:` syntax rather than inventing a new state API.
- SVD quality varies; the overlay mechanism is essential, not optional.
- Conservative WCET can cry wolf; the report-first rollout is deliberate.
- Built-in tracing must stay near-zero cost or it becomes another Heisenbug;
  word-writes to a preallocated ring only, never formatting on the hot path.

## 7a. How the industry copes today (and what we adopt)

The honest answer to "how do veterans live with ISR preemption without static
analysis?": they do not eliminate it — they **shrink it until a human can hold
it in their head**, then apply a small set of battle-tested patterns with
near-religious discipline.

**The trodden path:**

- **The ISR does almost nothing** ("top half" / "bottom half"): acknowledge the
  peripheral, capture one word, post it, return. All real work runs in task
  context. A short ISR has a small preemption window, so few interleavings
  exist.
- **Single-writer ownership, written down**: teams keep a literal *shared-data
  table* — variable, who writes, who reads, what protects it. This is the
  manual ancestor of the compiler report in §8.1 #4.
- **Tiny critical sections**, `CPSID i` / `BASEPRI` around a few instructions;
  "keep it short" enforced by review and GPIO/DWT measurement, not by the
  compiler. Nesting counted so interrupts aren't re-enabled too early.
- **Lock-free handshakes**: SPSC ring (head owned by producer, tail by
  consumer), double buffering / DMA ping-pong, seqlocks, and `WFE`/`SEV`
  instead of flag + `WFI` (a sticky event bit makes lost wakeups impossible).
- **No allocation in ISRs, ever** — static pools, preallocated message slots;
  a hard review gate and a MISRA-style rule.
- **RTOS APIs split by context**: FreeRTOS forbids `xQueueSend()` from an ISR
  and provides `xQueueSendFromISR()` instead. The API split *is* the
  discipline. Tuck should mirror this with an ISR-safe `send` primitive.
- **Hardware as guardrail**: deliberate NVIC priority map, `BASEPRI`,
  bit-banding, MPU, separate MSP/PSP stacks, DMA; watchdog as backstop.
- **Verification by stress, not proof**: soak/torture tests with interrupts
  hammered at max rate across voltage/temperature; trace and GPIO timing;
  deliberately widening a critical section to expose a race.
- **Process instead of types**: MISRA C / CERT C, naming conventions, checklists,
  review. C static analyzers catch uninitialised variables and overruns but are
  weak on ISR preemption — that needs whole-program interrupt-context and
  atomicity reasoning C cannot express.

It works because "tiny ISR + few documented shared variables + short critical
sections" reduces the state space to something a careful human can enumerate.
It is fragile for the same reason: the discipline lives in people's heads and
documents, and decays with turnover. Tuck's move is not to invent new best
practices but to **turn these exact ones into checked rules**, using their
existing vocabulary so the path feels familiar.

| Manual practice today | Tuck equivalent to add |
|---|---|
| ISR posts to a preallocated SPSC slot | An ISR-safe `send` primitive, allocation-free by construction |
| "No malloc in ISR" taboo | `[no_alloc]` / `[irq_safe]` effects checked through call edges |
| Shared-data table in the docs | Generated shared-access report (SARIF/JSON) |
| "Keep critical sections short" | Static bound + `tuck timing` report of longest masked interval |
| Priority map / nesting policy | Declared priorities with priority-ceiling checks |
| Soak tests / widen-the-window trick | Deterministic interrupt-storm fault injection in the QEMU loop |
| Watchdog + safe state | Declarative `watchdog` / `safeState` (§8.2 #7) |

**Two additions this inspires (beyond §8):**

- **A distinct ISR call surface** — `sendFromIsr`, `poolTakeFromIsr`, etc.,
  rather than one API with a runtime check. The FreeRTOS lesson: the *name* of
  the call is the discipline; the wrong path should not exist.
- **A "widen the window" test mode** — a compile flag inserting deliberate
  delays at every preemption point, so fault-injection runs expose races
  instead of relying on luck. This formalises the veteran's trick.

---

## 8. Loose edges — notes for the future

This is a very large milestone; several items below are future features, not
work for the next session. They are recorded so nothing is lost. Each item is
tagged with when it matters and, where applicable, the **existing convention or
file format** to use so developers can parse the output with tools they already
have (see also §9).

### 8.1 Refinements to the four layers (settle before steps 0–6)

1. **A stable event / crash binary format** — *settle before step 5.* The ring
   buffer (Layer 3) and the crash dump need a format shared between target and
   host decoder. Define it once, versioned, or recorder and decoder drift apart.
   Prefer an existing container: emit records as **ELF `NOTE` sections** with a
   vendor namespace, and export the decoded view as **JSON**. ELF notes are
   readable by `readelf`/`objdump` and are the same mechanism core dumps use;
   JSON is universally parseable.
2. **Verify debug info early** — *check during step 0, before promising Layer 3.*
   `tuck decode-crash` maps PC→Tuck line only if emitted code carries line
   tables. Check whether Nim `--os:standalone` output has usable **DWARF**; if
   not, the compiler must emit a side-table. DWARF is the standard GDB/LLDB
   consumes — if present, `tuck build --debug` gets source-level debugging for
   free (see #10).
3. **SVD overlay semantics** — *part of step 1.* Define merge/conflict rules for
   vendor corrections ("patch this field's reset value", "this reserved bit is
   writable on rev B"). Use **CMSIS-SVD** as the base (the format vendors ship
   and `svd2rust` parses) and **device tree overlays (`.dtbo` / DTS syntax)** for
   board-level wiring, pin mux, and clock corrections — both are formats
   embedded developers already parse with `dtc` and vendor toolchains.
4. **Escape hatches must be loud** — *design principle for steps 1–3.* Typestate
   and ISR discipline need `steal()`-style bypasses for driver authors (Rust has
   this). Make them impossible to trigger accidentally: an explicit keyword, a
   diagnostic that cannot be silenced, and a report listing every escape hatch
   in the build. "Fearless" means the loopholes are visible. Report them in
   **SARIF** alongside audit results (§9).

### 8.2 Next-wave tools — what makes the four layers *usable* (high value)

5. **Virtual board + `pending:` for hardware** — *fold into steps 0/6.* Declare
   a `board` with peripherals, compile and **run** against a simulated board
   before the PCB exists — the same typed-hole workflow Tuck already uses for
   programs. Describe the board in **device tree (DTS/DTSI)**, the format Linux
   and embedded vendors already use, reusing `stdlib-project`'s
   `platform.devicetree`. This attacks "approachable" at the root: a developer
   designs and runs firmware before any hardware exists.
6. **Clock tree as a declaration** — *Layer 1, as important as registers.*
   STM32 clock setup (PLL multipliers, bus dividers, peripheral limits, wrong
   UART baud) is a legendary time-sink. Make clocks declarative; the compiler
   computes frequencies, checks each peripheral's maximum, generates the
   register writes, and prints the tree. Express it with standard **device tree
   clock bindings** (`clocks`, `clock-names`, `assigned-clock-rates`), which
   `dtc` and vendor tools already understand.
7. **Watchdog + safe state as language constructs** — *Layer 1/2.* A `watchdog`
   declaration tied to task liveness: the compiler ensures each critical task
   feeds it and generates the feed. A `safeState` for outputs, guaranteed at
   startup and on any fault path. Removes "device bricked / actuator left on"
   bugs. This is the "fearless" feature par excellence; feed/failure events go
   into the event ring (#13).
8. **Power-state effects** — *Layer 1.* `sleep`/`stop`/`standby` as declared
   effects: check which peripherals and IRQs can wake from each mode and that
   clocks/register config are restored after wake. "Woke from stop mode with
   the wrong clock" becomes a compile error. Map modes to standard **device
   tree power-domain bindings**.
9. **Probe abstraction: `tuck flash`, `tuck probe`, `tuck monitor`** — *Layer 3/4
   usability.* Hide OpenOCD/pyOCD/probe-specific commands behind one CLI: flash,
   reset, read the event ring, dump crash state. Wrap **OpenOCD/pyOCD** and
   **CMSIS-DAP**, and accept their standard `.cfg` files — a newcomer shouldn't
   need to learn three probe toolchains to use the built-in observability.
10. **Source-level GDB via DWARF** — *same check as #2.* If emitted code has line
    tables, `tuck build --debug` gives GDB/Tuck source-level debugging for free.
    Standard **DWARF** + **GDB remote serial protocol** over the existing probe.
11. **Virtual time in the QEMU loop** — *refinement of Layer 4.* A 1 Hz blink
    shouldn't take a wall-clock second to test. Run with an accelerated virtual
    clock and inject timer interrupts deterministically so days of simulated
    time pass in seconds. This is what makes Layer 4 usable for real timing
    tests rather than smoke tests.
12. **Fault injection in simulation** — *pairs with #7 and #11.* Deliberately
    flip register bits, drop an interrupt, stall a clock, exhaust a pool — then
    assert the program still reaches its `safeState`. "Fearless" means you've
    seen it fail on purpose. Record results in **JUnit XML** so CI dashboards
    parse them.

### 8.3 Domain gaps (small, high value for approachability)

15. **Fixed-point ranges and boundary literals** — Tuck has `[saturating]` /
    `[wrapping]`, but MISSING-FEATURES **A51** ("minimum of a signed type cannot
    be written") is a known paper cut. Fix it and add range-checked fixed-point
    types using standard **Q notation** (`Q7.8`, `Q15.16`) that DSP developers
    already use.
16. **Audit stdlib for `[irq_safe]`** — `platform.hal` / `platform.interrupt`
    exist, but nobody has verified that stdlib paths callable from an ISR are
    allocation-free and effect-clean. One-time audit + a CI guard makes the ISR
    discipline (#1b) credible. Emit findings as **SARIF**.
17. **MPU configuration from `platform.boot` regions** — *later.* Those regions
    already describe memory; generate **ARM MPU** regions from them so a stack
    overflow or wild write hits a HardFault. Complements `flip-link` with
    hardware protection on cores that have an MPU.
18. **Board self-checks** — *cheap.* stdlib modules have a `main` of self-checks
    run on all backends; do the same for board packages: a `main` that verifies
    register maps, pin mux, and clock config in simulation. Catches board-file
    mistakes before hardware; results in **JUnit XML**.
19. **Multi-backend clarity on metal** — *doc decision.* The experiment uses
    Nim; Odin has a freestanding target; D's story is unclear. Newcomers will
    ask "which backend do I use for MCU work?" Answer explicitly with a support
    matrix in the README, or "approachable" fails at the first question.

### 8.4 Later / north star

13. **Zero-overhead profiling from the event ring** — *refinement of Layer 3,
    after the ring exists.* Add **DWT cycle-counter** reads and `tuck profile`
    renders a timeline/flamegraph. Export as **CTF (Common Trace Format)** so
    Babeltrace / Trace Compass — the tools trace engineers already use — can
    open it. *QEMU caveat (2026-11-21): QEMU 8.2 does not emulate DWT, so the
    current guest clock (`systick_clock.tuck`) reads the SysTick down-counter
    instead. A real `tuck profile` should prefer DWT on hardware and fall back
    to SysTick under emulation — but that needs the T5 CTF/egress decision
    first.*
14. **"Explain my crash"** — *north star, needs Layers 3 + 5.* Given a crash dump
    + event ring, emit a diagnosis in Tuck terms, not just data: "task X was
    waiting on mailbox Y, which was full because consumer Z was blocked on
    `[io]` at line 42." The tool stops giving information and tells you what
    went wrong — AI-assisted diagnosis built on structured, compiler-generated
    facts. Deliver the explanation as **SARIF** results + Markdown so it lands
    in CI/PR UIs.
20. **HIL CI / board rack** — *for teams.* `tuck test --hardware` on a rack of
    boards, results in **JUnit XML**. Not needed for individual approachability,
    but it is how the guarantees stay honest across MCU revisions.

### 8.5 Scope discipline — explicitly *not* building (revisit, don't calcify)

- **A general RTOS** — actors + tasks + the deterministic stackless scheduler
  *are* the concurrency model; wrapping an RTOS would reintroduce the bugs we
  are removing.
- **A GUI IDE** — one CLI (`tuck flash`, `tuck probe`, `tuck audit`, `tuck
  timing`) plus editor integration is enough; the research shows the pain is
  tooling fragmentation, not the absence of a GUI.
- **Hand-written packages for 100 MCUs** — SVD + overlay or nothing.
- **WCET as a hard gate on day one** — report first, opt-in gating, as in §6.

## 9. Conventions and file formats — use what developers already parse

Every output should land in a format an embedded developer's existing toolchain
already reads. This is a deliberate constraint: it makes the tools adoptable
and makes our output composable with the tools in §1's ladder rather than
competing with them.

| Concern | Use this convention | Tools that already parse it |
|---|---|---|
| Register / peripheral metadata | **CMSIS-SVD** (vendor XML) | `svd2rust`, vendor packs, SVD parsers |
| Board wiring, pin mux, clocks, power domains | **Device Tree** `.dts`/`.dtsi` + **overlays** `.dtbo` | `dtc`, Linux, vendor SDKs; Tuck's `platform.devicetree` |
| Diagnostics, audit findings, escape-hatch list, crash explanation | **SARIF 2.1.0** | GitHub code scanning, Azure DevOps, GitLab |
| Timing / audit metrics (machine-readable) | **JSON** (+ CSV for tables) | `jq`, spreadsheets, dashboards |
| Debug info and source-level debugging | **DWARF** + **GDB remote serial protocol** | GDB, LLDB, IDEs |
| Event trace / profiles | **CTF (Common Trace Format)** | Babeltrace, Trace Compass |
| Crash dump container | **ELF `NOTE` sections** + JSON-decoded view | `readelf`, `objdump`, our decoder |
| Probe / flash control | **OpenOCD / pyOCD / CMSIS-DAP** config conventions | existing probe scripts and `.cfg` files |
| Test / fault-injection results | **JUnit XML** | CI dashboards (Jenkins, GitHub, GitLab) |
| Fixed-point types | **Q notation** (`Q7.8`, `Q15.16`) | DSP libraries, existing developer habit |

Where no standard exists, use a **versioned JSON schema** and publish it; never
invent a bespoke text format that needs a bespoke parser. The one deliberate
exception is the on-target ring record, which is a fixed-size binary word for
speed — but it is exported into CTF/JSON by `tuck trace`/`tuck decode-crash`, so
developers never have to parse the raw binary themselves.
