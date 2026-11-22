> **ARCHIVED 2026-11-22.** Superseded by `../VISION.md` (what and why) and
> `../ROADMAP.md` (what next). Kept for its rationale, its recorded traps and
> its observed QEMU results; do not plan from it. Where it disagrees with the
> two new files, they win.

# Execution plan — from this branch to fearless embedded Tuck

Status: living plan (2026-11-21). Supersedes the ordering tables in
`FREESTANDING-PLAN.md`, `EMBEDDED-DEBUGGING-VISION.md` and
`IMPLEMENTATION-GROUND.md` for *what comes next*; those documents remain the
design rationale. This one is about dependencies, exit criteria, and the very
next commands.

## 0. Where we are

**Done (this branch, `bdc10e1`+):** — latest `50c5e303` (T7 clock/board
finish); see the pause-point snapshot at the end of §0.

- QEMU feedback loop (`freestanding-loop.sh`) + board files in `boards/`.
- Freestanding runtime gates in `tuck_sl.nim` / `tuck_rt.nim` / `tuck.nim`.
- Full ISR-discipline slice: `[irq]` context, `tuck audit --isr`, TK-EF10/11,
  `critical:` node kind, JSON/SARIF reporter, ISR-safe SPSC handoff.
- Vendored picolibc 1.8.12 (Thumb) + `boards/build-picolibc.sh` + cross file.
- **Tasks now run to completion on bare metal**: `slHead`/`slTail`/`tuckSlDriving`
  are plain globals under `defined(freestanding)` (no TLS threadvar).
- Stages 9/10/12/13 boot under QEMU and print their success markers; host quick
  gate green.
- **T6 complete (2026-11-21):** `--debug-lines` maps faults to `.tuck` lines;
  `tuck decode-crash` decodes CFSR/HFSR and emits text/JSON/SARIF with TK-CR01
  (a warning); `tuck sim` auto-decodes a FAULT line. Green on the host suite
  and on three QEMU runs (precise fault, null branch, clean regression), with
  the dev-perspective readings in `IMPLEMENTATION-GROUND.md` §7a.
- **T19 complete (2026-11-21):** `tuck sim FILE --host` builds and runs Nim,
  Odin and D side by side against the shared shims; stage9 (task + print) and
  stage5 (two stackless tasks + HAL) produce byte-identical stdout on all
  three. `--backend:nim|odin|d` selects one; a missing compiler is `SKIP`.
- **T8 register import complete (2026-11-21):** a standalone Nim generator
  under `tools/svd2tuck/` turns one CMSIS-SVD into one importable Tuck module.
  Registers can cross module boundaries on Nim, Odin and D; the generated Blue
  Pill module has zero diff on the five registers used by
  `bare_metal_led.tuck`, and that program boots identically under QEMU.
  Typestate/sealed transitions remain a language decision, not a tool gap.
- **T7 complete (2026-11-21, `50c5e303`):** reusable SysTick guest clock
  (`systick_clock.tuck`; DWT is unemulated in QEMU 8.2) with deterministic
  `--tick:0..10` length control, plus a second QEMU board
  (`stm32vldiscovery`). Both boards print `CLOCK_OK` at shifts 0/4/10, pinned
  by `tests/suites/sim_tick.nim`.

**Resolved blocker:** task-based programs now run on metal. All three metal
runtime milestones (event ring, crash dump, virtual time) are implemented.

### Pause point — 2026-11-22 (review pass, branch `claude/tuck-baremetal-review-wm43kz`)

A review as a senior embedded developer; full findings in
`REVIEW-2026-11-22.md`. Fixed and pinned (new suite `metal_runtime`,
`isr_discipline` +4): the branch now builds on the CI-pinned Nim 2.2.4;
`critical:` saves and restores PRIMASK and restores on every exit
(try/finally, defer, scope(exit)); bounds/heap/arena/overflow failures on metal
print `PANIC:` and fault with the Tuck line instead of spinning silently; QEMU
runs end with main's return value (semihosting exit; 124 now means "still
running", never success); the ISR slot no longer overwrites an untaken value
and counts overruns; the event ring is IRQ-safe, wraps, and is off on hosted
builds; the ISR audit sees tasks and two-handler sharing. **T16 metal half
done**: `gdb-loop.sh STAGE LINE` stops gdb-multiarch at a `.tuck` line on the
QEMU target.

**Re-ranked next work (the user's ordering rule: finish partial features
before new ones).** The review found that the remaining T-items rest on
missing foundations, so these come first:

- **R1 — real interrupts.** Bind an `[irq]` fn to a vector, generate the
  table, and prove preemption under QEMU (SysTick or UART IRQ preempting a
  task). Today no interrupt is ever taken; every ISR test is a call from
  `main`. Unblocks R2, T17, T20's "drop a real interrupt", and a long time base.
- **R2 — timed wait + idle.** A SysTick-driven `sleep` that parks a frame,
  and `WFI` when the ready list is empty. Without it every delay blocks all
  tasks.
- **R3 — write-1-to-clear registers.** A field spelling and a codegen rule
  that never read-modify-writes a w1c register; svd2tuck to stop dropping
  `modifiedWriteValues`.
- **R4 — optimised freestanding build** (`-Os`, section GC) behind the QEMU
  suite; the cost model's numbers mean nothing at -O0.

T5→T20 (trace egress), T11 (`[period:, deadline:]`) and T13 (Q notation)
remain decision-blocked, as below.

### Pause point — 2026-11-21 (branch `claude/freestanding-baremetal-qemu`, HEAD `50c5e303`)

A stable, verified checkpoint; paused here deliberately, NOT merged to `main`.

- **Landed:** T1–T4, T6, T7 (clock + tick control + board parity), T8 register
  half, T11 coarse scorer, T16 host half, T19, ISR slice, ring/count.
- **Verified:** both QEMU boards green at ticks 0/4/10 (`CLOCK_OK`, qemu 124);
  `sim_tick`, `complexity`, `sim_host`, `crash_decode`, `timing_report`,
  `svd_import`, `end_to_end`, `examples`, `quick-test.sh`, `doc_snippets` all
  green; no examples/goldens diff; tree clean at the commit.
- **Not merged:** this branch is pushed for safekeeping only. Integration into
  `main` is a separate decision.
- **Known-red suites (pre-existing, unrelated to staged work):** `effect_fix`
  (invalid Odin memo code), `resources_rt` (duplicate `_mco_*` symbols),
  `roadmap` (cascade), `stdlib_project` (3 `hci` failures).
- **Resume here:** §3 item 16 (T5→T20 CTF/egress — needs an egress decision) or
  item 15 (T11 rest — needs `[period:, deadline:]` language surface). Both are
  blocked on a decision, not code; route around with parked items if continuing
  without one. Higher-end boards (M4 `mps2-an386`, M7 `mps2-an500`) are deferred
  until a feature needs their peripherals.

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
  T18 tuck sim      (needs T3,T4) ──► T19 host sim ──► T20 virtual time

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

### T3 — Full vector table and fault handlers  [T2]  [S]  ✅ DONE

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

### T5 — Compiler-instrumented event ring  [T4]  [M]  ◐ PARTIAL

- **Outcome:** a fixed, pool-backed ring in RAM recording task switches, ISR
  entry/exit, `[io]` calls and mailbox-full events as timestamped words.
- **Files:** new `compiler/event_ring.nim` or additions to `tuck_sl.nim`; CTF
  export through the done reporter layer.
- **Exit:** a QEMU run produces a CTF file that Babeltrace can read, showing
  two tasks interleaving.
- **Built:** the 256-entry tag/word ring in `compiler/tuck_sl.nim`; task
  switches and ISR posts write one word each; `tuckEventDump` reports the head
  count over semihosting (`stage10` prints `HEAD=2` under QEMU).
- **Still to do:** no `tuck trace` command exists, the per-event ring contents
  are never lifted out of the ELF, and CTF metadata is not emitted. The
  Babeltrace gate is therefore **not** met. Needs a decision on how events
  leave the target (semihosting log vs ELF note) before building.

### T6 — Crash dump + source decoder  [T5, done reporter]  [M]  ✅ DONE

- **Outcome:** a FAULT line from the metal handler → `tuck decode-crash` maps
  PC/LR to Tuck source lines and emits text/JSON/SARIF through the shared
  reporter (no Markdown renderer was needed — SARIF is the tool-parseable form
  the vision asked for, and the text form carries the what/why/fix reading).
- **Files:** `compiler/crash_decode.nim`, `compiler/diagnostics.nim` (TK-CR01),
  `compiler/codegen*.nim` + `tuck.nim` (`--debug-lines`), the naked fault
  handler in `boards/startup_lm3s6965evb.c`, `host_sim/fault_shim.nim`,
  `freestanding-loop.sh`, `tests/suites/crash_decode.nim`.
- **Exit (observed):** `tuck sim stage16_precise_fault.tuck` prints
  `stage16_precise_fault.tuck:19` as the call site and exits 1; stage11 exits 0.
  The precise fault is an unaligned store (`CCR.UNALIGN_TRP`), not the wild
  MMIO write first imagined — QEMU ignores unmapped stores on this board.

### T7 — Virtual time + fault injection  [T4, T5]  [M]  ✅ DONE (clock + injection)

- **Outcome:** the QEMU loop runs with an accelerated virtual clock; a test
  flag flips register bits / drops an interrupt / stalls a clock at every
  preemption point and asserts the program still reaches `safeState`.
- **Exit:** stage 8's 1 Hz blink simulated in seconds; a fault-injected run
  produces a reproducible failure + event trace.
- **Built:** a reusable SysTick guest clock (`systick_clock.tuck`) with
  deterministic tick-length control. QEMU 8.2 does not emulate DWT, so the
  clock reads SysTick's 24-bit down-counter (no interrupt; polled, ISR-safe);
  `clock_init` warms the ptimer counter before sampling because QEMU's
  `PTIMER_POLICY_NO_IMMEDIATE_RELOAD` delays the first reload by one edge.
  `--tick:N` (`0..10`, each step doubles virtual ns per instruction) sets
  QEMU `-icount shift=N,sleep=off`; `--time:fast` is the `shift=10` preset.
  `--fault:isr-drop` compiles with `-d:TuckFaultIsrDrop`. All are QEMU-only
  and ignored by `--host`. A board profile (`TUCK_BOARD`) selects the QEMU
  machine, CPU, linker script and initial SP; `lm3s6965evb` and
  `stm32vldiscovery` both boot `stage17_clock` cleanly (`CLOCK_OK`, qemu 124)
  at shifts 0, 4 and 10. The "reaches `safeState`" assertion belongs to T17;
  the event-trace half is T20 and waits on T5's CTF export.
- **Pinned:** `tests/suites/sim_tick.nim` checks `--tick` rejection
  (`11`, `-1`, non-numeric, empty) and boots the clock fixture on both boards;
  it SKIPs cleanly without QEMU / the ARM toolchain / vendored picolibc.

### T8 — SVD → register declarations + typestate  [none]  [L]  ◐ PARTIAL

- **Outcome (shipped):** a standalone Nim tool generates `register` decls from
  one SVD into one importable Tuck module; a JSON overlay patches vendor
  mistakes. Compiler-side change: imported registers are copied into the
  importer and Odin/D qualify their accessors to the defining module.
- **Exit (met):** `testing_experiment/tools/svd2tuck/generated/stm32f103_bluepill.tuck`
  has the same addresses and used fields as `bare_metal_led.tuck`; the generated
  program checks, builds on three backends and boots under QEMU identically.
  Pinned in `tests/suites/svd_import.nim`.
- **Still to do:** sealed transitions + singleton ownership need a Tuck type
  surface; field enums, reset values and read actions have no `register`
  spelling. Parked, not deferred to this tool.

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

### T11 — `tuck timing` reports  [none; validates against T4]  [M]  ◐ PARTIAL

- **Built (2026-11-20):** `tuck timing FILE` reports worst-case
  **critical-section nesting** per fn and an **approximate worst-case stack**
  along the resolved call graph, worst-first. Output is text, JSON
  (`--format:json`), or SARIF 2.1.0 (`--format:sarif`, TK-TM01/TM02 as
  warnings). The stack number SUMS the call path; it is a budget flag, not a
  measurement.
- **Scoring function done (2026-11-21):** `compiler/cost_model.nim` computes a
  coarse worst-case cycle score from the checked AST — small per-node weights,
  worst branch, constant-range loop trip counts, callee scores through
  `calleeDecl`, and notes for anything unprovable or unmodelled. `tuck timing`
  prints it in text and JSON (`cost[].cyclesApprox`, `exact`, `notes`); the
  report says plainly that it is not a measured WCET. A budget table keyed by
  `Decl.id` is the deadline seam: a declared `deadline:` will become that fn's
  cap for callers and an overrun note, with no change to the scorer. Verified
  by a direct probe: plain 3 cycles -> cap 40 gives 40; cap 2 gives 3 plus
  "exceeds declared max 2".
- **Still to do:** `[period:, deadline:]` syntax to fill the budget table;
  task utilization, longest masked interval, and deadline gating in reports.
- **Exit (remaining):** a JSON + Markdown report for every example; a
  deadline declaration that cannot be met is flagged.

### T12 — MPU regions from `platform.boot`  [T3]  [S]

- **Outcome:** ARM MPU regions generated from the declared memory regions.
- **Exit:** a deliberate wild write HardFaults instead of corrupting `.bss`.

### T13 — Q-fixed-point + A51  [none]  [S]  ◐ PARTIAL

- **Outcome:** standard Q notation (`Q7.8`, `Q15.16`) with range checks;
  MISSING-FEATURES A51 (minimum of a signed type) fixed.
- **Exit:** pinned in `known_bugs`; examples compile on all three backends.
- **A51 is done:** `known_bugs` carries `bugFixed` for `-128` as an `i8`, and
  the full/host suites are green. Only the Q-notation half remains, and that
  is a new type-surface decision (spelling, range-check point, all three
  backends) — not a leaf. MISSING-FEATURES now records the fix.

### T14 — Virtual board with `pending:`  [host-first: none; parity: T4]  [L]

- **Outcome:** design and run firmware against a simulated device tree before
  hardware exists — the top-down typed-hole workflow applied to hardware.
- **Exit:** a `pending:` sensor driver runs against a virtual board and prints
  its call log; then the real driver fills the hole unchanged.

### T15 — Probe CLI  [T5]  [M]

- **Outcome:** `tuck flash`, `tuck probe`, `tuck monitor` wrap
  OpenOCD/pyOCD/CMSIS-DAP and read the event ring.
- **Exit:** a developer can flash + dump the ring with one command per action.

### T16 — Source-level GDB  [T3]  [S]  ✅ DONE (QEMU; a real probe is T15)

- **Outcome:** `tuck build --debug` with usable DWARF; GDB RSP over the probe.
- **Exit:** break at a Tuck source line on real hardware / QEMU.
- **DWARF half verified (2026-11-21):** the `tuck sim` ELF has `.debug_info`,
  `.debug_abbrev` and `.debug_line`; `objdump --dwarf=decodedline` names
  `stage9_minimal_task.tuck` with line 6 at `0x99a` and line 7 at `0x9b4`.
- **Host half done and pinned:** `tuck b FILE --debug-lines --nim:"--passC:-g"`
  makes a host binary a batch gdb can stop in at a `.tuck` line. The command
  is `gdb -q -batch -ex 'set debuginfod enabled off' -ex 'break FILE.tuck:N'
  -ex run -ex bt --args BIN`; `tests/suites/crash_decode.nim` pins it and
  reports SKIP when gdb is absent. No new CLI flag was needed.
- **Blocked:** no ARM-capable debugger is installed (`/usr/bin/gdb` is x86
  only; no `gdb-multiarch`, no `arm-none-eabi-gdb`), so the metal break cannot
  be observed here. **Resolving signal:** an ARM gdb on PATH; then run
  `qemu-system-arm -s -S -kernel ELF` and the same batch script against `:1234`.

### T17 — Declarative watchdog + safeState  [T4]  [M]

- **Outcome:** compiler ensures critical tasks feed the watchdog; outputs are
  guaranteed in a safe state at startup and on every fault path.
- **Exit:** fault injection (T7) proves the safe state is reached.

### T18 — `tuck sim`: build + run under QEMU in one command  [T3, T4]  [S]  ✅ DONE

- **Outcome:** a developer runs `tuck sim file.tuck` and gets a sub-second test
  cycle instead of a 10-minute flash-and-see. Captures semihosting output,
  exit code, and fault reports.
- **Exit:** clean run prints program output and exits 0; fault run prints
  `FAULT PC=...` and exits 1. Verified with stage11, stage14.

### T19 — `tuck sim --host`: fastest path  [none]  [S]  ✅ DONE

- **Outcome:** builds against host sim shims, runs in milliseconds, no
  cross-toolchain needed. Validates logic and scheduler.
- **Exit:** `tuck sim file.tuck --host` completes in <1s with correct output.
- **Three targets (owner, 2026-11-21):** verification is not done on Nim alone.
  Nim, Odin and D must all build and run the same stage with byte-identical
  stdout. To make that possible `host_sim/print_shim` and `host_sim/hal_shim`
  each have a `.nim`, `.odin` and `.d` twin; the Odin files share one
  `package host_sim` because the emitted import names the directory, while D
  imports each module by bare name. `host-loop.sh` runs all three available
  backends by default (missing compiler = reported SKIP), and
  `tuck sim FILE --host --backend:NAME` selects one. Pinned cases: stage9
  (task + print) and stage5 (two stackless tasks + HAL). Both were measured
  identical across all three backends before this line was written.

### T20 — Fault-injected event trace  [T4, T5, T18]  [M]  ◐ PARTIAL

Was "Virtual time + fault injection", which duplicates T7. The virtual clock
and `--fault:isr-drop` are T7 and are done; what remains here is the trace half
of T7's exit criterion.

- **Outcome:** a fault-injected run produces a reproducible failure plus a
  per-event trace showing where the handoff was dropped.
- **Exit:** a 1 Hz blink completes in <100ms wall time; a fault-injected run
  produces a reproducible failure + event trace.
- **Depends on T5's open half:** the ring records events but nothing lifts them
  out of the target or writes CTF. Do not start this before the CTF format and
  the event-egress path (semihosting log vs ELF note) are chosen.

### T6 detail — staged execution plan (2026-11-21)

This is the working breakdown for item 12 in §3. Every stage ends in an
observed result (a command + its output), not "code written". A stage is not
done on host evidence alone where a QEMU check exists. Each stage is small
enough to fit one feedback loop; if a check fails, fix that stage before
opening the next one.

**Stage 1 — Tuck line numbers reach DWARF (host proof)**

1.1 `CodegenCtx` carries `lineInfo`/`srcPath`; `emitNim` passes them through;
`genStmt` wraps statements in `{.line: ("file.tuck", N).}:` only when on.
1.2 `tuck` turns `--debug-lines` into that emit state and appends
`--lineDir:on` to the `nim c` flags, so Nim writes `#line` into the C.
1.3 Host proof: build a small file with `--debug-lines` and `--passC:-g`;
`addr2line -e BIN -f -C ADDR` must say `file.tuck:N`, not `file.nim:N`.
1.4 Guard the default: without `--debug-lines` the emitted Nim is unchanged,
so tracked `examples/` need no re-emit.

Exit: the `addr2line` result is recorded, and `git diff examples/` is empty
after a normal `tuck c`. Status: **all done** — a host build mapped `0x65d0`
to `lineinfo_fresh.tuck:2`; re-emitting examples left `git diff examples/`
empty and the default emit carries zero line pragmas (the `--debug-lines`
emit carries them). The regression suite pins the same property on a host
binary built from a two-line `.tuck`.

**Stage 2 — a complete, parseable fault record on metal**

2.1 `startup_lm3s6965evb.c`: print `BFAR=` and `xPSR=` alongside the existing
`PC`/`LR`/`CFSR`/`HFSR` fields. Keep the `KEY=value` shape so a script can
parse it without a regex guess.
2.2 Add `stage16_precise_fault.tuck`: a directly called shim performs an
unaligned 32-bit store while `CCR.UNALIGN_TRP` is set. This was chosen over the
planned wild MMIO write after QEMU ignored stores to every unmapped address
tried (`0x60000000`, `0x80000000`, `0xFFFFFFF0`, …). The fault is *precise*: the
stacked PC names the faulting instruction. Stage14's indirect null call turned
out to be `INVSTATE`, not the `IMPRECISERR` the pre-naked handler appeared to
show — that earlier reading was really R2 from a compiled C prologue.
2.3 QEMU run must print one FAULT line and halt, with no "Lockup".

Exit: `FAULT PC=... LR=... CFSR=... HFSR=... BFAR=... xPSR=...` observed, with
CFSR `0x01000000` = `UNALIGNED` (and HFSR `0x40000000` = `FORCED`) — a precise
UsageFault, not an imprecise bus fault with an unreliable stacked PC.

**Stage 3 — decoder module `compiler/crash_decode.nim`**

3.1 Parse a fault record from `--log:FILE` or explicit `--pc/--lr/--cfsr/
--hfsr/--bfar` flags; tolerate the `FAULT ` prefix and hex with/without `0x`.
3.2 Decode CFSR's MMFSR/BFSR/UFSR bits and HFSR bits into plain language;
say explicitly when the PC is imprecise (IMPRECISERR) and must not be trusted
as the faulting instruction.
3.3 Resolve PC via `arm-none-eabi-nm -n` (nearest symbol, Thumb bit masked)
and via `arm-none-eabi-addr2line -f -C` (Tuck file/line); keep both, because a
symbol explains *what code* and a line explains *where to edit*.
3.4 Render text as what happened / why it matters / how to fix it; JSON and
SARIF 2.1.0 through `report_format`, with one new registered code
(`TK-CR01`, a warning) so GitHub's code-scanning UI can show a fault site.

Exit: decoding a captured log names the symbol and, for a precise fault, the
Tuck line; an imprecise fault is labelled as such and not given a fake line.

**Stage 4 — CLI and `tuck sim` integration**

4.1 Rewrite `tuck decode-crash ELF PC` to use the module, keeping the old
two-positional form working and adding the flags from 3.1 plus
`--format:json|sarif`.
4.2 `freestanding-loop.sh` prints `ELF=<path>` so one captured log is
self-describing; pass `--debug-lines` for sim builds.
4.3 `tuck sim` detects a FAULT line, finds the ELF, and prints the decoded
report before exiting 1. A clean run still exits 0.

Exit: one `tuck sim stage16_precise_fault.tuck` prints the decoded Tuck line.

**Stage 5 — regression suite `tests/suites/crash_decode.nim`**

5.1 Table-test the status-bit decoder (precise bus fault vs imprecise vs
MemManage vs UsageFault) without needing QEMU.
5.2 Assert log parsing, `--format:json` and `--format:sarif` shape (rule id,
location), and `tuck explain TK-CR01`.
5.3 Host DWARF mapping: write a two-line `.tuck`, build with `--debug-lines`,
look up a function address with `nm` and ask `addr2line` for it; SKIP the
assertion when `nm`/`addr2line` are absent.
5.4 Register the suite in `tests/suites/regen.py` QUICK set; run the named
suite and `./quick-test.sh`.

Exit: suite green, no golden churn, no new SKIP in the normal environment.

**Stage 6 — QEMU end-to-end, developer's eye**

6.1 `tuck sim stage16_precise_fault.tuck`: report names the Tuck call site
(`stage16_precise_fault.tuck:19`) and explains the unaligned store + fix.
6.2 `tuck sim stage14_fault.tuck`: report says `PC=0` is a null target with no
symbol, decodes `INVSTATE`, and points at LR for the call site. (The planned
IMPRECISERR wording was wrong: the fault is precise, and earlier evidence came
from a non-naked handler that printed R2 as the PC.)
6.3 `tuck sim stage11_irq_marker.tuck`: clean run stays green (no regression).

Exit: all three outputs (rc 1, 1, 0) pasted into `IMPLEMENTATION-GROUND.md`
§7a with a short what/why/fix reading, not just a pass/fail line.

**Stage 7 — docs, gates, commit**

7.1 Update §0/§3 here, the README developer loop, `IMPLEMENTATION-GROUND.md`
(a new T6 layer note), and `tuck help decode-crash`/`tuck help sim`.
7.2 Run `./quick-test.sh`, `./tests/run --quick`, `tools/doc_snippets --list`,
`git diff examples/`, and the QEMU checks from stage 6 one final time.
7.3 Commit on `claude/freestanding-baremetal-qemu`; do not push.

Exit: a commit whose message names the verified QEMU result (`gsd` is not
clean: these experiment files and the new suite are part of the commit). Then
return to §3's next item (T19 host sim).

## 3. Immediate next actions (in order)

T1–T4 are **complete** (picolibc vendored, tasks run to completion on metal).
T3 (full vectors) is also **complete** — the default handler records PC/LR/xPSR/
CFSR/HFSR/BFAR and prints a one-line FAULT report; `tuck decode-crash ELF PC`
maps the PC to the nearest symbol. T5's **ring half** is complete:
`tuckEventDump` reports the ring count over semihosting; its CTF-export half
remains and is tracked as T20. T7 (virtual time + fault injection), T18
(`tuck sim`) and T8's register-import half are **complete**. T7 now includes
a reusable SysTick guest clock with deterministic `--tick:N` length control
and a second QEMU board (`stm32vldiscovery`), both green under QEMU and pinned
by `sim_tick.nim`. T11 is **partial**:
`tuck timing` now reports critical-section nesting and an approximate
worst-case stack (text/JSON/SARIF); WCET, utilization and deadline gating
remain.

Remaining:

12. ~~**T6 — crash dump + decoder.**~~ **DONE (2026-11-21).** `--debug-lines`
    puts Tuck coordinates in DWARF; the decoder maps PC/LR through `nm` +
    `addr2line` and emits text/JSON/SARIF with TK-CR01; `tuck sim` auto-decodes
    FAULT lines. Verified on three QEMU runs (§7a of the ground doc) and pinned
    by `tests/suites/crash_decode.nim`.
13. ~~**T19 — `tuck sim --host`.**~~ **DONE (2026-11-21).** Nim + Odin + D,
    byte-identical output on stage9 and stage5; pinned by `sim_host.nim`.
14. ~~**T7 (rest) — SysTick clock, deterministic tick length, board parity.**~~
    **DONE (2026-11-21).** `systick_clock.tuck` reads the SysTick down-counter
    (DWT is unemulated in QEMU 8.2); `--tick:0..10` sets a fixed `-icount`
    shift and `--time:fast` is the shift-10 preset. Added the
    `stm32vldiscovery` board profile (machine/CPU/linker/SP); fixed the shared
    Cortex-M startup and an EABI-correct assembly `__aeabi_read_tp` (a C
    version clobbered r3, faulting every TLS/overflow-trap read on the STM32
    board), plus a freestanding-safe `tuckOverflowTrap`. Both boards print
    `CLOCK_OK` at shifts 0/4/10; `sim_tick.nim` pins parsing and both scenarios.
    Higher-end boards (Cortex-M4 `mps2-an386`, M7 `mps2-an500`) stay deferred
    until a board needs their peripherals.
15. **T11 (rest) — WCET, task utilization, longest masked interval, deadline
    gating.** The stack + critical-nesting report is built; these need the
    call graph's timing facts and `[period:, deadline:]` declarations. Neither
    spelling appears anywhere in the AST or parser today, so this is a
    language-surface decision, not an independent leaf.
16. **T5 (rest) → T20 — CTF export, then fault-injected event trace.** The ring
    and its head count exist; there is no `tuck trace`, no event egress from
    the target, and no CTF metadata. Crosses runtime + CLI + reporter — pick
    the egress path (semihosting log vs ELF note) before building; SPAWN
    candidate.
17. ~~**T8 — SVD importer (register half).**~~ **DONE (2026-11-21).**
    Standalone Nim tool, vendored MIT parser front half, Apache-2.0 SVD input,
    committed whole-device and Blue Pill modules, imported-register seam fixed
    in all three backends, 11/11 in `svd_import.nim`, QEMU `124` on the
    generated-register fixture. Remaining typestate is parked behind a type
    decision.
18. **T13 (rest) — Q notation.** A51 is fixed and pinned as `bugFixed`; the Q
    spelling and the range-check point are a type-surface decision.
19. ~~**T16 (rest) — break at a Tuck line in GDB.**~~ **DONE (2026-11-22).**
    `gdb-loop.sh stage9_minimal_task 10` boots the ELF halted under QEMU with
    a gdbstub and gdb-multiarch stops at `stage9_minimal_task.tuck:10`;
    pinned in `metal_runtime` (SKIP without an ARM gdb). Real-probe flashing
    stays with T15.

PARKED with resolving signals: T12 (`platform.boot` declaration does not
exist), T15 (no debug probe attached), T17 (needs a `watchdog:` declaration
and T20's trace), T9/T10 (depend on T8), T14 (L, depends on the top-down
`pending:` workflow reaching hardware parity).

Each ends with: rebuild tuck (clean Nim cache after enum changes), run the
affected `tests/run` suite, run `freestanding-loop.sh <stage>`, and write a
short dev-perspective note into `IMPLEMENTATION-GROUND.md`.

## 4. Decisions — all settled

1. **picolibc source:** pinned tarball, vendored under `vendor/picolibc/`.
2. **Semihosting in picolibc:** off; `say`/crash dumper use raw `BKPT`.
3. **Lane priority:** T1–T4 first, then T11 in parallel with T5/T6.
4. **SVD generator:** standalone Nim tool, not a `tuck svd` subcommand; adapt
   svd2nim's MIT parser front half, discard its Nim emitter, no Rust stage.
5. **SVD input:** Apache-2.0 `modm-io/cmsis-svd-stm32`, not svd2nim's
   unlicensed test copy.

No decision is currently awaiting the owner. Open items are parked in §3 with
resolving signals; T8's typestate half waits on a type-surface decision, not a
generator decision.

## 5. Hard rules carried forward

- QEMU verification at every step — no host-only "green".
- Dev-perspective review at every step — diagnostics/reports must say what,
  why, and the fix without reading compiler source.
- Functions identified by `Decl.id`, names only in display.
- New diagnostic codes append to their category block; clean Nim cache after
  any enum change.
- Hosted-only section edits must be checked for freestanding impact (and vice
  versa) — the `opened*: MonoTime` regression is the cautionary tale.
