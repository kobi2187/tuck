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
type Uart [transitions:
  Unconfigured -> Configured
  Configured   -> Active]:
  ...

# `uart.write` exists only on Uart in state Active; calling it on
# Unconfigured is a compile error, like today's sealed state machines.
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
