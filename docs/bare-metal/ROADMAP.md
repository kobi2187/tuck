# Bare-metal roadmap

Status: rebuilt 2026-11-22 from the four earlier plans, the review
(`REVIEW-2026-11-22.md`) and `VISION.md`. **This is the only file that says
what to do next on the metal track.** It replaces `EXECUTION-PLAN.md` (now in
`archive/`). The main `ROADMAP.md`'s work queue points here.

Ordering rule (the owner's, applied to this track): **bugs first, then
finish partial features, then design decisions, then new features.** Every
phase below ends in an observed result on a named rung of the evidence
ladder (VISION §4.9), never "code written".

| Rung | Means |
|---|---|
| ch | `tuck ch` / a check-level suite assertion |
| host | `tuck sim --host`, all three backends |
| qemu | `tuck sim` (QEMU), exit status + output asserted |
| renode | Renode script, peripheral state asserted |
| hw | a real board through a probe |

---

## Where it stands (2026-11-22)

**Works, pinned by tests** (suites in brackets):

- Freestanding Nim build for Cortex-M3: picolibc (Thumb), startup, two QEMU
  boards (`lm3s6965evb`, `stm32vldiscovery`) [`sim_tick`, `metal_runtime`].
- Stackless tasks interleave on metal; fire-and-forget tasks drain after
  `main` [qemu, two_tasks, task_await, task_fire_forget].
- `register` access incl. SVD-generated modules across module boundaries, on
  three backends [`svd_import`].
- `[irq]` marker, ISR reachability, `tuck audit --isr` (text/JSON/SARIF),
  TK-EF10 gate under `--isr-check:error`, TK-EF11 (no I/O, waits or
  allocation inside `critical:`), tasks and two-handler sharing included
  [`isr_discipline`].
- `critical:` saves/restores PRIMASK and restores on every exit, three
  backends [`metal_runtime`].
- Loud failures: bounds/heap/arena/overflow/Nim panic → `PANIC:` + FAULT +
  the Tuck line; QEMU exit status = main's return; 124 = still running
  [`metal_runtime`].
- Crash decoding: CFSR/HFSR in words, PC/LR → `.tuck` line via DWARF
  (`--debug-lines`), SARIF TK-CR01 [`crash_decode`].
- One-word ISR hand-off with overrun counting; event ring (IRQ-safe,
  wrapping) with a count over semihosting [`metal_runtime`].
- `tuck timing`: critical nesting, approximate stack, coarse cycle score
  (report only) [`timing_report`].
- Source breakpoints: host gdb, and gdb-multiarch on the QEMU target
  (`gdb-run.sh`) [`crash_decode`, `metal_runtime`].
- `tuck sim --host` byte-identical output on Nim/Odin/D [`sim_host`].

**Not there yet** (ranked in the review): no real interrupt is ever taken;
no timed wait or `WFI` idle; register writes read-modify-write w1c registers;
-O0 builds; ~4.6 KB hidden RAM; QEMU-grade linker scripts; semihosting-only
output (faults on hardware without a debugger); metal is Nim-only; host sim
is 64-bit only; and **nothing is reusable across applications yet**: each
register instance is its own global (`USART1_SR`, `USART2_SR`) and `[irq]`
is written on the handler, so a driver cannot be shared (VISION §2a).

---

## Phase 0 — Make the metal path a `tuck` feature, then merge

The experiment is a branch with shell scripts. The longer it stays one, the
further it drifts from `main` (it already failed to build on the CI toolchain
once). Merge early, behind a clear boundary.

| ID | Work | Exit | Rung |
|---|---|---|---|
| 0.1 | `--freestanding` as a real flag implying stackless + `--frames:heap` (until 1.3) + `--actors:single` + the freestanding Nim flags; `tuck build --board:NAME` reads a board descriptor (machine, CPU, linker, SP, console) instead of `TUCK_BOARD` arms in a script | `tuck build --board:lm3s6965evb `task_await` produces the same ELF as `qemu-run.sh`; the script becomes a thin wrapper | qemu |
| 0.2 | Board files split per board (today one `startup_cortex_m.c` serves both); `tuck_board_exit`/`tuck_fatal`/console in a per-board `board.c` | stm32vldiscovery has its own startup; both boards green | qemu |
| 0.3 | ~~**D10**: picolibc as pinned tarball + SHA-256~~ **DONE 2026-11-22**: `boards/picolibc/build.sh` fetches the 1.8.12 release (byte-identical to the vendored tree, `diff -rq` empty) and checks its SHA-256 | the 4,193 vendored files are gone; QEMU suites green on the fetched build | qemu |
| 0.4 | ~~CI job for the metal toolchain~~ **DONE 2026-11-22**: CI installs `qemu-system-arm gcc-arm-none-eabi gdb-multiarch meson ninja-build` and builds picolibc once (cached). On PR #226 the metal suites ran on GitHub, not SKIP: `metal_runtime` 10/10 (incl. the gdb breakpoint on the target), `sim_tick` 6/6, `crash_decode` 13/13 | green on a PR; metal suites never SKIP in CI | qemu |
| 0.5 | ~~**D11**: move to `boards/`, `tools/metal/`, `tests/metal/` stages~~ **DONE 2026-11-22**: `testing_experiment/` is gone; docs in `docs/bare-metal/`, programs renamed by what they prove | `git grep testing_experiment` only in the archive | ch |
| 0.6 | Merge to `main`; spec Part 8/9 and `LANGUAGE-OVERVIEW` get a "bare metal (experimental)" section listing what works; `roadmap.nim` pins each "works" claim above as `featureDone` and each Phase 2–4 item as `featureMissing` | `./tests/run` + `roadmap` green on main | ch |

## Phase 1 — Correct foundations (finish what exists)

**1.0 comes first and is design, not code.** Per VISION §2a, interrupt
binding, frame homes, register-block instances, priorities and deadlines
are application-level choices a reusable driver must never make. No
spelling lands before the owner rules on them.

| ID | Work | Exit | Rung |
|---|---|---|---|
| 1.0 | **Design round** for D13 (leading direction: interrupts as registry events, `DESIGN-interrupt-events.md`, questions E-Q1..E-Q7), then D1, D2, D8, D12: write the reuse-test programs (one unchanged UART driver; two applications on two boards with different instances, lines, priorities and load) in pseudo-Tuck under two or three competing designs; compare what the application must write in the common case and how the error reads when the compiler cannot infer | a short design note in `docs/` with the candidates side by side, and the owner's ruling recorded in the main `ROADMAP.md` rulings ledger | — |
| 1.0a | **Finish the event registry to its spec** (no ruling needed): more than one handler per event, in declaration order (E1); `latest` (E2); handlers inside an actor, delivered as messages once E-Q2's reading is confirmed (E3); behavioural tests on all three backends (E4) | the three `featureMissing` "Part 10" pins in `roadmap.nim` flip to `featureDone` | host |
| 1.1 | `-Os -ffunction-sections -fdata-sections -Wl,--gc-sections` for metal builds | every metal program green at -Os; flash for `task_await` drops (record before/after) | qemu |
| 1.2 | Remove the TLS/GOT hack: `-ftls-model=local-exec`, or emit Nim's threadvars as plain globals under freestanding | `tuck_tls`, asm `__aeabi_read_tp` and the stm32 `.got` copy deleted; both boards green | qemu |
| 1.3 | **D2** (after 1.0): static frame homes, counts inferred from the whole program where knowable, an application-level bound where not; `--frames:static` becomes the metal default; the bump heap goes | `task_fire_forget` compiles with no annotation (two spawn sites, count inferred); `panic_frame_heap`'s data-dependent spawn is refused with an error naming the site and asking the application for a bound; `freestandingHeap` gone | ch + qemu |
| 1.4 | Generated linker script from board regions: reserved + checked stack, `ALIGN(4)` section ends, `.noinit` crash record, flip-link layout | a deliberate stack overflow faults instead of corrupting `.bss`; the crash record survives a reset | qemu |
| 1.5 | RAM/flash budget printed by `tuck build`, error over budget | budget for `task_await` matches `arm-none-eabi-size` within the stack reservation | qemu |
| 1.6 | **D3** (after 1.0) w1c / write-only fields as chip-package facts; svd2tuck keeps `modifiedWriteValues`; codegen never RMWs such a register | a w1c status register write emits a single store of the mask (emits pin); STM32 USART SR fields generated as w1c | ch |
| 1.7 | **D4** 32-bit host sim for metal boards | an `int` overflow at 2^31 traps in `tuck sim --host` as it does on QEMU | host |
| 1.8 | Fault handler picks MSP/PSP from EXC_RETURN; decoder fixes: `--debug-lines` no longer attributes the entry wrapper to the `.tuck` file | gdb backtrace shows no `.tuck` line past the file's length | qemu |
| 1.9 | ISR audit keys state by declaration id, not name; protection required on the preemptible side only | a local named like a register is not "shared"; an ISR's own access no longer needs `critical:` | ch |
| 1.10 | Stage hygiene: scratch state in SRAM, never peripheral space; LED stages read back GPIO where the simulator models it | no stage writes `0x40000000` as scratch | qemu |
| 1.11 | **D12** (after 1.0): register blocks as instance-generic types; svd2tuck maps `derivedFrom` onto one layout with several instances | one UART driver module drives USART1 and USART2 in one program, emitted code identical in cost to the hand-specialised version; existing `register NAME at ADDR` programs unchanged | ch + qemu |

## Phase 2 — Real interrupts

Depends on Phase 1.4 (vector table lives in the generated layout).

| ID | Work | Exit | Rung |
|---|---|---|---|
| 2.1 | svd2tuck emits the interrupt list (name → number); board build generates the full vector table; unbound vectors go to a default handler whose FAULT line names the vector | `nm` shows every vector; an unexpected IRQ reports its name | qemu |
| 2.2 | **D1** (as ruled in 1.0; leaning: a line raises a registry event, DESIGN-EVENTS E6): the application binds lines to driver handlers; the compiler places them and enables the lines | a **SysTick handler preempts a busy task** and both observe a shared counter correctly; an unbound or doubly-bound line is a compile error | qemu |
| 2.3 | UART RX interrupt (PL011 on lm3s, fed through QEMU's serial) | bytes typed on QEMU stdin reach a task via the handler | qemu |
| 2.4 | Priorities from the application's bindings; ceiling analysis over the composed program; `critical:` lowers to a BASEPRI raise to the resource's ceiling (PRIMASK on M0) | a higher-priority handler runs inside a low ceiling's section; M0 build (QEMU `microbit`) still correct | qemu |
| 2.5 | ISR audit uses priorities: two-handler sharing gated exactly when priorities differ | the "same priority" caveat is gone from the report | ch |
| 2.6 | Fault injection from outside: an interrupt storm and a dropped interrupt driven by the harness (QEMU gdbstub / Renode), not by the program | `fault_isr_drop` rewritten without `faultIsrDrop()`; the injected run is reproducible | qemu |
| 2.7 | **The reuse test, for real:** the 1.0 programs as Tuck. One unchanged UART driver in two applications on the two QEMU boards, different instances, lines and priorities | both build and run; each gets its own correct ceilings; `git diff` of the driver between the two is empty | qemu |

## Phase 3 — Waiting on hardware (the metal reactor)

Depends on Phase 2.2. Closes spec §9's "not designed yet".

| ID | Work | Exit | Rung |
|---|---|---|---|
| 3.1 | Runtime contract §4.6 written in `docs/`; `park`/`wake`/`idle` in the Nim runtime | contract doc + one runtime test exercising each call | qemu |
| 3.2 | Monotonic 64-bit clock on SysTick; `sleep` parks the frame | two tasks blinking at 100 ms and 250 ms interleave in the right order and the ready list empties between ticks | qemu |
| 3.3 | `WFI` idle with the race-free sequence | instruction count (`-icount`) during a 1 s sleep is near zero, not a busy loop | qemu |
| 3.4 | Typed ISR queues (generalise the one-word slot); a task awaits one | UART echo through a queue, overruns counted | qemu |
| 3.5 | `on select` over queues and timers | "echo UART, blink at 1 Hz, time out after 5 s idle" in one program | qemu |
| 3.6 | Extern waits declared against a wait source; nothing on metal uses a helper stack | `--frames:static` accepts `two_blinkers` and `actor_mailbox` once their HAL waits are declared | ch + qemu |

## Phase 4 — Observability on real transports

Depends on Phase 3.2 (timestamps) and 0.2 (per-board console).

| ID | Work | Exit | Rung |
|---|---|---|---|
| 4.1 | **D5** console channel per board: semihosting (QEMU), UART, RTT | the same program prints on QEMU (semihosting) and on Renode (UART) | qemu + renode |
| 4.2 | Deferred-format logging: strings in the ELF, id + args on the wire; `tuck log` decodes | a `say` with interpolation costs one record on the device | qemu |
| 4.3 | Event ring egress over the channel with timestamps; `tuck trace` → JSON + CTF | Babeltrace 2 reads a QEMU trace showing two tasks interleaving (old T5/T20 exit) | qemu |
| 4.4 | Crash record in `.noinit`, reported on next boot; "explain my crash" joins fault + last ring records | a watchdog-reset run reports the previous fault and the task that was running | qemu |

## Phase 5 — Proven budgets

| ID | Work | Exit | Rung |
|---|---|---|---|
| 5.1 | Stack from `-fstack-usage` joined to the call graph and ISR priority levels; `[stack: N]` a hard error | the reported worst case is ≥ the measured high-water mark (stack painting) on every stage | qemu |
| 5.2 | Measured cycles per stage and handler (QEMU `-icount`; DWT on hardware) beside the static score | report shows both; the static score is calibrated or dropped | qemu |
| 5.3 | **D8** (as ruled in 1.0): periods and deadlines stated by the application; a library may state guarantees; utilisation and longest masked interval | a task set over 100% utilisation is flagged (old T11 exit), with the driver unchanged between two applications | ch |

## Phase 6 — Peripherals as types

| ID | Work | Exit | Rung |
|---|---|---|---|
| 6.1 | Peripheral singletons + sealed `transitions:` for sequencing | writing a pin before configuring it is a compile error; two drivers on one pin is a compile error | ch |
| 6.2 | Clock tree declaration (old T9) | a wrong PLL divider is a compile error; generated writes match today's hand-written setup | ch + renode |
| 6.3 | DMA transfers as owned values | using a buffer during its transfer is a compile error | ch |
| 6.4 | Board self-checks in simulation (old T10), JUnit output | registered in a suite; Renode runs them | renode |
| 6.5 | `extern [c]` against a vendor SDK (STM32Cube HAL or pico-sdk) | one stage calls a vendor C HAL function and links | qemu |

## Phase 7 — Real hardware

| ID | Work | Exit | Rung |
|---|---|---|---|
| 7.1 | `tuck flash` / `tuck run --board` over probe-rs or OpenOCD, RTT console (old T15) | one command flashes a Blue Pill and shows its log | hw |
| 7.2 | Blue Pill: LED, UART echo, SysTick blink, a fault decoded from hardware | the four stage results match QEMU | hw |
| 7.3 | RP2040 (Cortex-M0+, different vendor: PRIMASK only, a second SVD) | same four results | hw |
| 7.4 | **The real firmware** (VISION §1): 5–10k lines, sensor node | runs a week on a bench without a reset; built on two boards | hw |

## Phase 8 — Backends in tandem on metal (parallel lane)

Starts once the runtime contract (3.1) is written. Owner rule: a feature
lands on all three backends or with a pinned, tracked gap.

| ID | Work | Exit | Rung |
|---|---|---|---|
| 8.1 | D via LDC `-betterC -mtriple=thumbv7m-none-eabi` against the contract | `task_await`, `critical_nest`, `panic_bounds` green on QEMU in D | qemu |
| 8.2 | Odin `-target:freestanding_arm32` against the contract | same three stages in Odin | qemu |
| 8.3 | `metal_runtime` runs every QEMU stage on every metal backend | three-backend metal parity, like `sim_host` | qemu |

## Phase 9 — Safety features

| ID | Work | Exit | Rung |
|---|---|---|---|
| 9.1 | Watchdog + `safeState` declarations (old T17) | an injected hang (2.6) resets into `safeState`, reported by 4.4 | qemu |
| 9.2 | MPU regions from `platform.boot` (old T12) | a wild write faults with MemManage, decoded | qemu |
| 9.3 | Power-state effects (what wakes from `stop`, clocks restored) | waking with the wrong clock is a compile error | ch |

## Independent lanes (no metal dependency)

- **Q notation (old T13, D9).** Type surface + range checks, three backends.
- **Virtual board / `pending:` for hardware (old T14).** The `platform.*`
  host doubles plus Renode as the "board that does not exist yet".
- **`[irq_safe]` audit of the stdlib** (vision §8.3 #16 of the old plan):
  every stdlib path reachable from an ISR checked, SARIF report.

---

## Dependency graph

``text
Phase 0 (feature + merge) ──► Phase 1 (foundations)
                                 │
                 1.4 layout ─────┼──► Phase 2 (interrupts) ──► Phase 3 (reactor)
                                 │          │                     │
                 1.3 instances ──┘          ├──► 2.6 injection    ├──► Phase 4 (observe)
                                            │                     ├──► Phase 5 (budgets)
                                            └──► 2.4 priorities ──┘
Phase 3.1 contract ──► Phase 8 (D, Odin on metal)        Phase 6 needs 1.6 + 2.2
Phase 7 (hardware) needs 1.4 + 2.2 + 4.1                 Phase 9 needs 2.6 + 4.4
``

Critical path to the flagship ("blink + UART echo, interrupt-driven, idle
CPU, on hardware, with a reusable driver"): 0.1 → **1.0** + 1.0a → 1.4 → 2.1 → 2.2 →
2.7 → 3.2 → 3.3 → 3.4 → 4.1 → 7.1 → 7.2. Everything in Phase 0 and items
1.1, 1.2, 1.4, 1.5, 1.7–1.10 can proceed while 1.0 is being decided.

## Old task IDs → new

| Old | Was | Now |
|---|---|---|
| T1–T4 | picolibc, link, vectors, tasks on metal | done; 0.3 replaces the vendoring |
| T5 | event ring | ring done; egress + CTF → 4.3 |
| T6 | crash decoder | done; 1.8 + 4.4 extend it |
| T7 | virtual time + injection | clock done; real injection → 2.6; timed waits → 3.2 |
| T8 | SVD → registers | registers done; instance-generic blocks → 1.11; interrupts → 2.1; w1c → 1.6; typestate → 6.1 |
| T9 / T10 | clock tree / board self-checks | 6.2 / 6.4 |
| T11 | `tuck timing` | report done; real numbers → 5.1/5.2; deadlines → 5.3 |
| T12 | MPU | 9.2 |
| T13 | Q notation, A51 | A51 done; Q → independent lane |
| T14 | virtual board | independent lane |
| T15 | probe CLI | 7.1 |
| T16 | source GDB | done (QEMU); hardware → 7.1 |
| T17 | watchdog + safe state | 9.1 |
| T18 / T19 | `tuck sim`, `--host` | done; 32-bit host → 1.7 |
| T20 | fault-injected trace | 2.6 + 4.3 |

## Decisions (from VISION §7)

Design questions (through 1.0, judged by the reuse test): D13 first, then
D1 → 2.2, D2 → 1.3, D3 → 1.6, D8 → 5.3, D12 → 1.11; D9 → independent lane.
Plumbing (recommendations in VISION §7): D4 → 1.7, D5 → 4.1, D6 → 4.1/6.x,
D7 → Phase 8, D10 → 0.3, D11 → 0.5. Phase 0 needs only D10 and D11.

## How to work on this track

``sh
nim c --hints:off -o:tuck tuck.nim
./tests/run metal_runtime sim_tick crash_decode isr_discipline   # metal gate
TUCK_SKIP_TUCK_BUILD=1 ./tuck sim tests/metal/PROGRAM.tuck  # one program, QEMU
./tuck sim tests/metal/PROGRAM.tuck --host                  # three backends
./tools/metal/gdb-run.sh STAGE LINE                      # break on target
``

Each item ends with: the named suite green, the stage's QEMU output pasted
into the commit message or the review log with a what/why/fix line, and this
file's row marked done with the commit id.

## Traps (each has cost a session)

1. **A test that cannot fail.** Every metal stage must fail visibly when
   wrong: assert the exit status, not just a printed marker. A silent hang
   once read as success for every stage.
2. **Stale Nim cache after an enum change** (`compiler/diagnostics.nim`):
   codes shift by one. `rm -rf ~/.cache/nim/tuck_d` before trusting a result.
3. **Freestanding edits in hosted-only code** (and vice versa): ask which
   builds include a file before editing it (`tuck_rt_stdlib_externs.nim` is
   hosted-only).
4. **A C fault handler is not naked**: its prologue shifts the stacked frame
   and prints R2 as the PC. Keep the handler naked.
5. **Addresses stay numeric** through the decoder; formatting then reparsing
   turned `0x15a` into `0x346`.
6. **QEMU ignores stores to unmapped addresses** on these boards; use
   `CCR.UNALIGN_TRP` for a precise fault.
7. **The toolchain pin is the toolchain.** Build with the CI's Nim 2.2.4: a
   newer Nim hid a missing `findIt` and a doubled `panic` for 30 commits.
8. **-O0 hides ordering bugs.** When 1.1 lands, expect volatile and barrier
   bugs to surface; they were always there.
9. **A board fact in a driver** (an instance, a line, a priority, a count) is
   a reuse bug even when it works. The reuse test (2.7) is the check.
