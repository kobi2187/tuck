# Execution plan — from this branch to fearless embedded Tuck

Status: living plan (2026-11-20). Supersedes the ordering tables in
`FREESTANDING-PLAN.md`, `EMBEDDED-DEBUGGING-VISION.md` and
`IMPLEMENTATION-GROUND.md` for *what comes next*; those documents remain the
design rationale. This one is about dependencies, exit criteria, and the very
next commands.

## 0. Where we are

**Done (this branch, `bdc10e1`+):**

- QEMU feedback loop (`freestanding-loop.sh`) + board files in `boards/`.
- Freestanding runtime gates in `tuck_sl.nim` / `tuck_rt.nim` / `tuck.nim`.
- Full ISR-discipline slice: `[irq]` context, `tuck audit --isr`, TK-EF10/11,
  `critical:` node kind, JSON/SARIF reporter, ISR-safe SPSC handoff.
- Vendored picolibc 1.8.12 (Thumb) + `boards/build-picolibc.sh` + cross file.
- **Tasks now run to completion on bare metal**: `slHead`/`slTail`/`tuckSlDriving`
  are plain globals under `defined(freestanding)` (no TLS threadvar).
- Stages 9/10/12/13 boot under QEMU and print their success markers; host quick
  gate green.

**Resolved blocker:** task-based programs now run on metal. The remaining
runtime work (event ring, crash dump, virtual time) is unblocked.

## 1. Dependency graph

```
LANE 0 — FOUNDATIONS (done)
  [done] shared reporter (JSON/SARIF)
  [done] ISR discipline (audit, TK-EF10/11, critical:, SPSC)
          │
          ├──────────────┬─────────────────────────────┐
          ▼              ▼                             ▼
LANE 1 — METAL RUNTIME   LANE 2 — STATIC FEATURES      LANE 3 — APPROACHABILITY
  T1 vendor+build           T8  SVD→registers+typestate   T14 virtual board + pending:
     Thumb picolibc            │                              (host-first; metal parity
          │                    ├─► T9  clock tree              after T4)
          ▼                    └─► T10 board self-checks
  T2 link tuck to it       T11 tuck timing (stack/WCET)   T15 probe CLI
          │                    │                              (flash/probe/monitor)
  T3 full vectors+faults   T12 MPU regions               T16 GDB/DWARF source debug
          │                    │                              (needs T3)
  T4 tasks complete       T13 Q-fixed-point + A51        T17 watchdog/safeState
     under QEMU               (unblocked, independent)       (needs T4)
          │
          ├──► T5 event ring ──► T6 crash dump + decoder
          │                       (T6 also needs done reporter)
          └──► T7 virtual time + fault injection
                 (T7 also needs T5 for observability)

Critical path to the two flagship outcomes:
  "tasks work on metal"        = T1 → T2 → T3 → T4
  "explain my crash"           = T1 → T2 → T3 → T4 → T5 → T6
```

Lane 2 and Lane 3 do **not** block the critical path and can be interleaved
whenever Lane 1 is waiting on a toolchain/download.

## 2. Tasks

Each task has: **ID**, **depends**, **outcome**, **files**, **exit criterion**.
Effort is S (<1 session), M (1–3 sessions), L (>3 sessions).

### T1 — Obtain and build a Thumb picolibc  [depends: none]  [S]  ✅ DONE

- **Outcome:** a static `libc.a` whose `memset`/`memcpy` are Thumb code, plus
  matching headers, at a pinned path under `testing_experiment/`.
- **Known starting point:** `/home/kl/prog/nimLinux_experiment/tools/picolibc_build.sh`
  builds picolibc with sensible flags (`single-thread`, no TLS, `semihost`
  optional). Its `vendor/picolibc` submodule is **empty** and `meson` is not on
  PATH here — both must be resolved first.
- **Steps:**
  1. Make meson available (`apt install meson ninja-build` or pip).
  2. Populate a pinned picolibc source (submodule update or a downloaded
     release tarball), vendored under `testing_experiment/vendor/picolibc`.
  3. Create a cross file for `arm-none-eabi` / Cortex-M3 (Thumb, soft-float),
     and a build script `testing_experiment/boards/build-picolibc.sh`.
  4. Do **not** enable picocrt/startup — we supply `startup_lm3s6965evb.c`.
     Enable semihosting only for `printf` support (optional; our `say` already
     uses a raw `BKPT`).
- **Exit:** `arm-none-eabi-objdump -d <libc> | grep '<memset>:'` shows Thumb
  instructions (`strb`, `uxtb`, `.thumb_func`), not `e92d…` ARM prologues.
- **Decision needed:** vendor a pinned tarball (reproducible, larger diff) vs
  a git submodule (small diff, needs network at build). Pick: pinned tarball.

### T2 — Link Tuck's freestanding builds against picolibc  [T1]  [S]  ✅ DONE

- **Outcome:** `freestanding-loop.sh` no longer links newlib's ARM libc.
- **Files:** `testing_experiment/freestanding-loop.sh` (add `--passL:-nostdlib`
  plus explicit picolibc `libc.a` and our startup/stubs), possibly a small
  `compiler/tuck_sl.nim` adjustment if `memset` is still pulled from elsewhere.
- **Exit:** `stage9_minimal_task` (await a task returning a value) runs to
  completion under QEMU and prints its `TASK_OK` line.

### T3 — Full vector table and fault handlers  [T2]  [S]  ⏳ PENDING

- **Outcome:** all Cortex-M exceptions land in known handlers, not garbage.
- **Files:** `testing_experiment/boards/startup_lm3s6965evb.c`,
  `boards/lm3s6965evb.ld`, `boards/stubs.c`.
- **Details:** populate the vector table (NMI, HardFault, MemManage, BusFault,
  UsageFault, SVC, PendSV, SysTick); default handler records stacked
  PC/LR/xPSR/CFSR into a small RAM structure and halts; linker script exports
  its address for a future crash dumper.
- **Exit:** a deliberate fault (write to an unmapped address) from a QEMU run
  lands in the recorded handler instead of "Lockup: can't escalate …".

### T4 — Stackless tasks run to completion on metal  [T2]  [M]  ✅ DONE (T3 not required — tasks run now)

- **Outcome:** the first real concurrency milestone.
- **Files:** `stage8_freestanding_stackless.tuck`, `stage9_minimal_task.tuck`,
  `stage10_fire_forget.tuck` (fix whatever remains), possibly
  `compiler/tuck_sl.nim` (freestanding `tuckSlAwaitMain` / `tuckSlOnStack`).
- **Exit:** stage 8 prints both tasks' completion; stage 9 prints `TASK_OK`;
  all under QEMU with no fault, and the host quick gate still green.
- **Risk:** the earlier `tuckSlAwaitMain` spins on `s.done` while frames are
  driven by `tuckSlRunAll()`; if a frame never reaches its `return`, the loop
  is infinite (harmless in QEMU, but must be understood, not assumed).

### T5 — Compiler-instrumented event ring  [T4]  [M]

- **Outcome:** a fixed, pool-backed ring in RAM recording task switches, ISR
  entry/exit, `[io]` calls and mailbox-full events as timestamped words.
- **Files:** new `compiler/event_ring.nim` or additions to `tuck_sl.nim`; CTF
  export through the done reporter layer.
- **Exit:** a QEMU run produces a CTF file that Babeltrace can read, showing
  two tasks interleaving.

### T6 — Crash dump + source decoder  [T5, done reporter]  [M]

- **Outcome:** deliberate fault → ELF-note dump over semihosting →
  `tuck decode-crash` maps PC/LR to Tuck source lines, emits SARIF + Markdown.
- **Files:** new `compiler/crash_decode.nim`, fault handler from T3, DWARF
  check (vision §8.1 #2) in the build flags.
- **Exit:** `tuck decode-crash dump.bin` names the source line of the faulting
  `[io]` call in a stackless task.

### T7 — Virtual time + fault injection  [T4, T5]  [M]

- **Outcome:** the QEMU loop runs with an accelerated virtual clock; a test
  flag flips register bits / drops an interrupt / stalls a clock at every
  preemption point and asserts the program still reaches `safeState`.
- **Exit:** stage 8's 1 Hz blink simulated in seconds; a fault-injected run
  produces a reproducible failure + event trace.

### T8 — SVD → register declarations + typestate  [none]  [L]

- **Outcome:** `tuck svd chip.svd` generates `register` decls + sealed
  transitions + singleton ownership; a Tuck overlay patches vendor mistakes.
- **Exit:** a Blue Pill board package generated from its SVD checks the
  existing `bare_metal_led.tuck` with zero register diffs.

### T9 — Clock tree as a declaration  [T8]  [M]

- **Outcome:** standard device-tree clock bindings; compiler computes
  resulting frequencies, checks peripheral maxima, generates register writes,
  prints the tree.
- **Exit:** a wrong PLL divider is a compile error; the correct one generates
  the same registers as today's hand-written setup.

### T10 — Board self-checks  [T8]  [S]

- **Outcome:** board packages have a `main` of self-checks (register map, pin
  mux, clocks) run in simulation on all backends.
- **Exit:** registered in `stdlib_project` suite; results in JUnit XML.

### T11 — `tuck timing` reports  [none; validates against T4]  [M]

- **Outcome:** worst-case stack, conservative WCET, task utilization, longest
  masked interval — report first, opt-in gating later.
- **Exit:** produces a JSON + Markdown report for every example; deadline
  declarations `[period:, deadline:]` are flagged when exceeded.

### T12 — MPU regions from `platform.boot`  [T3]  [S]

- **Outcome:** ARM MPU regions generated from the declared memory regions.
- **Exit:** a deliberate wild write HardFaults instead of corrupting `.bss`.

### T13 — Q-fixed-point + A51  [none]  [S]

- **Outcome:** standard Q notation (`Q7.8`, `Q15.16`) with range checks;
  MISSING-FEATURES A51 (minimum of a signed type) fixed.
- **Exit:** pinned in `known_bugs`; examples compile on all three backends.

### T14 — Virtual board with `pending:`  [host-first: none; parity: T4]  [L]

- **Outcome:** design and run firmware against a simulated device tree before
  hardware exists — the top-down typed-hole workflow applied to hardware.
- **Exit:** a `pending:` sensor driver runs against a virtual board and prints
  its call log; then the real driver fills the hole unchanged.

### T15 — Probe CLI  [T5]  [M]

- **Outcome:** `tuck flash`, `tuck probe`, `tuck monitor` wrap
  OpenOCD/pyOCD/CMSIS-DAP and read the event ring.
- **Exit:** a developer can flash + dump the ring with one command per action.

### T16 — Source-level GDB  [T3]  [S]

- **Outcome:** `tuck build --debug` with usable DWARF; GDB RSP over the probe.
- **Exit:** break at a Tuck source line on real hardware / QEMU.

### T17 — Declarative watchdog + safeState  [T4]  [M]

- **Outcome:** compiler ensures critical tasks feed the watchdog; outputs are
  guaranteed in a safe state at startup and on every fault path.
- **Exit:** fault injection (T7) proves the safe state is reached.

## 3. Immediate next actions (in order)

1–6 above are **complete** (T1–T4, with the TLS threadvar discovery documented
in `IMPLEMENTATION-GROUND.md` §9a). Remaining:

7. **T3 — full vectors.** Populate the vector table + fault recorder; verify
   the deliberate-fault case lands in our handler. Not yet done; the table still
   has only the reset vector.
8. **T5 — event ring.** Now unblocked. First step: a fixed `pool`-backed ring
   in `tuck_sl` (freestanding) recording task switches, exported via
   `tuck trace`.
9. **T6 — crash dump + decoder.** Depends on T3 + T5.
10. **T7 — virtual time + fault injection.** Depends on T4 (done) + T5.
11. **T8 — SVD importer** (Lane 2, unblocked, can interleave).

Each ends with: rebuild tuck (clean Nim cache after enum changes), run the
affected `tests/run` suite, run `freestanding-loop.sh <stage>`, and write a
short dev-perspective note into `IMPLEMENTATION-GROUND.md`.

## 4. Decisions to confirm before starting

1. **picolibc source:** pinned tarball (my pick — reproducible) vs submodule.
2. **Semihosting in picolibc:** enable only for printf (my pick: leave it off;
   our `say`/crash dumper use raw `BKPT` already).
3. **Lane priority:** stay on Lane 1 to the metal milestone, or interleave T11
   (`tuck timing`) for an earlier developer-visible win. My pick: T1–T4 first,
   then T11 in parallel with T5/T6, because a task runtime that doesn't work
   undermines every later tool.

## 5. Hard rules carried forward

- QEMU verification at every step — no host-only "green".
- Dev-perspective review at every step — diagnostics/reports must say what,
  why, and the fix without reading compiler source.
- Functions identified by `Decl.id`, names only in display.
- New diagnostic codes append to their category block; clean Nim cache after
  any enum change.
- Hosted-only section edits must be checked for freestanding impact (and vice
  versa) — the `opened*: MonoTime` regression is the cautionary tale.
