> **ARCHIVED 2026-11-22.** Superseded by `../VISION.md` (what and why) and
> `../ROADMAP.md` (what next). Kept for its rationale, its recorded traps and
> its observed QEMU results; do not plan from it. Where it disagrees with the
> two new files, they win.

# Implementation, grounded: supporting layers first

Status: execution proposal (2026-11-19). Companion to
`EMBEDDED-DEBUGGING-VISION.md`. This document answers "how do we actually build
this?" with the constraint: **concise, disciplined, reuse existing machinery,
build small supporting layers, report before gate.**

## 0. The key realisation

Two of the vision's most important layers — **static prevention and static
reporting — do not need a working freestanding runtime**. They run on the host
today. The ISR-discipline work (the biggest pain) can start immediately, while
vendored picolibc (vision step 0) is prepared separately as the gate for the
*runtime* layers (event ring, crash decoder, virtual time).

So the sequencing is not a single chain: it is **two lanes**:

```
  STATIC LANE (host, unblocked now)      METAL LANE (blocked on picolibc)
  A. shared report emitter               0. vendor picolibc, full vector table
  B. ISR context in semantics            F. event ring + crash dump
  C. shared-access table + tuck audit    G. decoder + CTF export
  D. ISR gate + ISR-safe primitives      H. virtual time + fault injection
  E. tuck timing (stack/WCET/critical)
```

## 1. Ground rules

1. **Reuse, do not rebuild.** The effect/facts machinery already implements
   half the ISR discipline. Extend it rather than writing a parallel checker.
2. **One mechanism per concern.** One shared reporter (§2), one shared facts
   extension (§3), one diagnosis family (§5). No per-tool reimplementation.
3. **Report before gate.** Every new check ships as a warning + machine-readable
   finding first; it becomes a hard error only after the false-positive rate is
   understood. Controlled by a CLI flag (e.g. `--isr-check:warn|error`).
4. **Test first, per repo law.** Each new rule lands as a `bugOpen` pin in
   `tests/suites/known_bugs.nim` stating the *correct* behaviour; the check
   makes it pass and the marker flips to `bugFixed`. Nothing is deleted.
5. **Respect compiler invariants.** New diagnostics append at the end of their
   category in `compiler/diagnostics.nim` (never reuse numbers); a new language
   construct gets its own AST node kind; call edges come from
   `ast_query.calleeDecl`, never a re-derived name; walk with `ast_ops`.
6. **Formats from vision §9.** Machine output is JSON (+ SARIF for findings,
   CTF for traces, ELF notes for dumps). No bespoke text formats that need
   bespoke parsers.

## 2. What already exists (verify, then extend)

| Capability | Where | Notes |
|---|---|---|
| Effect markers incl. `[no_alloc]`, `[irq_safe]`, `[pure]` | `compiler/ast.nim` (`EffectMarker`, ~line 49) | `emIrqSafe`, `emNoAlloc`, `emPure` |
| Restriction call rule — a restricted fn's callees must declare the marker | `compiler/semantics.nim` `checkRestrictions` (~321) | TK-EF03, follows `resolveCallee` |
| ISR cannot send to an actor (mailbox locks) | `compiler/semantics.nim` `checkIsrSends` (~311) | TK-EF07; must gain a *local exception* for the new ISR-safe SPSC primitive |
| Allocate-syntax check | `compiler/semantics.nim` `checkNoAlloc` (~350) | TK-EF05; THE list to extend when new allocating syntax appears |
| No-recursion / static depth | `compiler/semantics.nim` `checkStackBound` (~381) | TK-EF06; only checks cycles today, does not compute a bound |
| Derived whole-program facts | `compiler/semantics.nim` `Facts`, `deriveFacts` (~649, ~753) | Fields already include `noAlloc`, `irqSafe`, `bounded`, `handler`, `isolated` |
| JSON report machinery | `compiler/effect_manifest.nim` `manifestOf` (~57) | The pattern for a machine-readable report; `tuck effects --manifest` already ships |
| Diagnostic registry | `compiler/diagnostics.nim` TK-EF block (~168) | Latest is TK-EF09; append TK-EF10+ |
| Test pins | `tests/suites/known_bugs.nim`, `tests/harness.nim` | `bugOpen` → `bugFixed`; `t.quietly` for outcome-only checks |

One thing to verify during implementation: how **module-level mutable state** is
represented (module-scope `dkExpr` vs a dedicated kind); the shared-access table
in §4 depends on it.

## 3. Supporting layer A — one shared reporter

Build new `compiler/report_format.nim` (small) with two emitters:
- **JSON** — extend the `effect_manifest` pattern; one stable schema per report
  (`audit`, `timing`, `decode-crash`), versioned.
- **SARIF 2.1.0** — a thin emitter from the same in-memory finding list
  (rule id, level, message, file/line, fixes). Findings use TK-EF diagnostic
  codes as SARIF rule ids, so GitHub/Azure/GitLab code-scanning UIs light up.

Every report tool (`tuck audit`, `tuck timing`, `tuck decode-crash`) uses this
layer. This is the "build supporting layers" principle in its purest form: the
format problem is solved once, before there are three tools to change.

## 4. Supporting layer B — ISR context in the semantic layer

Extend `Facts` with two derived booleans and one table:
- `isr*: bool` — reachable from an ISR handler (fixpoint over `calleeDecl`
  edges, mirroring `deriveFacts`; roots are fns declared as ISR handlers).
- `reentrant*: bool` — callable from both ISR and non-ISR contexts without
  static scratch state.
- a **shared-access table**: `(symbol, context, access, span, protected)` for
  module-level mutable state.

How ISR handlers are declared: add a context marker `[irq]` distinct from the
*restriction* `[irq_safe]`. `[irq]` marks an ISR entry point; `[irq_safe]` stays
the property a callee must have. This keeps the two concepts separate and
reuses `checkRestrictions` unchanged for the property.

Critical sections must become visible to the checker. The disciplined choice
per repo law is a new AST node kind `exkCritical` (a `critical:` block) with arms
in every traversal and backend — it lowers to `CPSID i`/`CPSIE i` (or
`BASEPRI`) on metal and to a lock/no-op on hosted. A cheaper name-based
prototype is possible for the *report* only, but the *gate* should use the node
kind so a `critical` block cannot be confused with an ordinary function call.

## 5. Supporting layer C — shared-access report + `tuck audit`

New pass, new `compiler/isr_access.nim`, builds the table from §4 and emits:
- a human table: variable, ISR sites, task sites, protected?;
- JSON + SARIF through layer A.

`Tuck audit --isr FILE` prints the table and writes findings. First test pins:
a torn counter (two writers), a flag read outside a critical section, and a
`printf`-like non-reentrant function reachable from an ISR. Initially all are
**warnings**; the suite asserts they are *reported*, not yet rejected.

## 6. Supporting layer D — the gate and the ISR-safe primitives

Append to the TK-EF block (permanent numbers):

| Code | Rule |
|---|---|
| TK-EF10 | Module-level state written by an ISR-reachable fn and read/written elsewhere must be declared `isrShared` |
| TK-EF11 | An `isrShared` access outside a `critical:` block |
| TK-EF12 | An ISR-reachable fn allocates or takes a lock (reuse EF05/EF07 machinery, new code for the ISR context) |
| TK-EF13 | A function reachable from both ISR and non-ISR contexts is not proven reentrant |

Gate rollout: `--isr-check:warn` default, `error` opt-in, flipping to default
`error` in a later release once the corpus is clean.

**ISR-safe primitives** (the FreeRTOS `FromISR` lesson): introduce
`sendFromIsr` / `poolTakeFromIsr` using preallocated SPSC slots — no lock, no
allocator. `checkIsrSends` gains a narrow exception for this one primitive.
Keep `tuckSlAlloc` (our bump allocator) **forbidden from ISR-reachable fns** by
TK-EF12; that closes the real correctness hole found in the experiment without
adding a lock to the hot path.

**Widen-the-window mode**: a compile flag inserting deliberate delays at each
preemption point (sends, critical-section exits, flag sets) for deterministic
fault-injection runs. Pairs with the metal lane's virtual time (§7).

## 7. Supporting layer E — `tuck timing` (reports first)

Extend the existing `checkStackBound` from "no cycle" to an actual bound:
- worst-case stack per fn from the call graph (`calleeDecl` edges, no recursion
  under `[no_recursion]`), including the ISR nesting chain;
- conservative WCET from a simple per-node cost model over the checked AST,
  with loop bounds from `for` ranges — report only, never gate initially;
- longest masked interval from `critical:` nesting depth × per-section cost;
- deadline declarations `[period: 1ms, deadline: 200us]`**, opt-in**, gated only
  when the author asks for it.

Output through layer A (JSON + SARIF + a Markdown table). This is the step that
turns "three days with a logic analyzer" into a line of `tuck timing`.

**Built 2026-11-20 (first slice).** `compiler/timing_report.nim` + the
`tuck timing` command report:
- critical-section nesting per body-owning decl, via `allDecls` + `ownExprs`
  (fn, task, `on select` arms, actor initialisers — the hand-rolled
  `decls` + `dkFn` walk missed all but the first);
- an approximate worst-case stack that SUMS frames along the deepest
  `calleeDecl` path and names the path (`main() -> top() -> middle()`);
- text, JSON, and SARIF 2.1.0 (`TK-TM01` nesting, `TK-TM02` stack, both
  warnings). The stack number is a budget flag, not a measurement; the text
  output says so.

Still to do: WCET, task utilization, longest masked interval, and
`[period:, deadline:]` gating. The dev-perspective check that shaped this
slice: a number without the path that produced it is not actionable, and a
report that calls an estimate an error teaches the reader to distrust it.

## 7a. Supporting layer F — `tuck decode-crash` (post-mortem source mapping)

T6 closes the loop the report layers opened: a fault on metal becomes something
a developer can act on without reading compiler source. It is two halves that
meet in the ELF.

- **On metal**, `boards/startup_cortex_m.c` prints one parseable
  `FAULT PC=... LR=... CFSR=... HFSR=... BFAR=... xPSR=...` line. The handler is
  `__attribute__((naked))`: it does `mov r0, sp; b recordFault`, so `sp[5..7]`
  really are the stacked LR/PC/xPSR. Before that fix a compiled C prologue
  shifted the frame four words, and the report printed R1/R2/R3 *as* LR/PC/xPSR
  — a convincing-looking lie that sent us to "PC in RAM". QEMU ignores stores
  to unmapped addresses on this board, so the precise fault is an unaligned
  32-bit store with `CCR.UNALIGN_TRP` set (`host_sim/fault_shim.nim`) rather
  than the wild MMIO write the plan originally imagined.
- **On the host**, `compiler/crash_decode.nim` parses that line (or explicit
  flags), decodes CFSR/HFSR bits into words, resolves PC/LR via
  `arm-none-eabi-nm -n` + `arm-none-eabi-addr2line`, and renders text / JSON /
  SARIF 2.1.0. `TK-CR01` is registered as a **warning** and SARIF says
  `level: "warning"` — a post-mortem report never gates a build. Emitted Nim
  carries `{.line: ("file.tuck", N).}:` pragmas **only** under `--debug-lines`,
  so DWARF names the `.tuck` rather than the generated `.nim`, and default
  codegen is byte-identical (`git diff examples/` clean after re-emit).

Three rules came out of getting this right, each from a wrong answer on the way:

1. `nearestSymbol`/`sourceLine` take numeric addresses. Formatting `$f.pc`
   produced the decimal string `"346"` for `0x15a`, which `hexVal` re-read as
   `0x346` and named `recordFault` instead of `preciseFaultStore`.
2. `PC=0` is a null target, not "nearest symbol at or below 0" (which names the
   vector table). The decoder says so and points at LR.
3. An imprecise fault never gets a source line from the PC; `bestSite` returns
   the caller. A buffered store faults several instructions later, so trusting
   the PC sends the developer to the wrong line.

### QEMU — precise fault (`tuck sim tests/metal/fault_unaligned.tuck`)

```
FAULT PC=0000015a LR=00000185 CFSR=01000000 HFSR=40000000 BFAR=00000000 xPSR=01000000
...
=== decoded crash ===
Crash: UsageFault (CFSR=0x01000000, HFSR=0x40000000)
  bit: UNALIGNED: unaligned word load/store (CCR.UNALIGN_TRP)
  bit: FORCED: a Mem/Bus/Usage fault escalated to HardFault
  What: UNALIGNED: unaligned word load/store (CCR.UNALIGN_TRP); escalated to HardFault because its handler was not enabled
  PC 0000015A -> preciseFaultStore_u0__...fault95shim (host_sim/fault_shim.nim:22)
  LR 00000185 -> tuckXCBX91fnXCBX91main__u0__stage1695precise95fault (call site fault_unaligned.tuck:19)
  Why: The stacked PC points at the failing instruction, so a source line can be recovered from DWARF built with --debug-lines.
  Fix: Align the address to 4 bytes, or use a byte/halfword access. Cortex-M traps unaligned word accesses when CCR.UNALIGN_TRP is set.
sim rc=1
```

**What happened.** A directly-called shim did an unaligned word store; the core
raised a *precise* UsageFault and the stacked PC names the faulting instruction.
**Why it matters.** PC and LR agree on one call chain, so the report can name
both the failing machine address and the Tuck line that led there — the developer
edits `fault_unaligned.tuck:19`, not a generated `.nim`. **How to fix it.**
Align the store or use byte/halfword accesses; the report says exactly that.
`sim` exits 1 because a FAULT line was present.

### QEMU — null branch (`tuck sim tests/metal/fault_null_call.tuck`)

```
FAULT PC=00000000 LR=00000189 CFSR=00020000 HFSR=40000000 BFAR=00000000 xPSR=40000000
...
=== decoded crash ===
Crash: UsageFault (CFSR=0x00020000, HFSR=0x40000000)
  bit: INVSTATE: invalid EPSR state (Thumb bit lost?)
  bit: FORCED: a Mem/Bus/Usage fault escalated to HardFault
  PC 00000000 -> (null target — no symbol)
  LR 00000189 -> faultWrite_u0__...fault95shim (call site host_sim/fault_shim.nim:12)
  Why: The core branched to address 0: there is no code there, so no source line can be named for the PC. LR still names the call site that performed the jump.
  Fix: A branch landed on an even address: Cortex-M Thumb code needs bit 0 set. Check a null or uninitialised function pointer, and decode LR-2 for the call site that made the jump.
sim rc=1
```

**What happened.** An indirect call through a null function pointer branched to
address 0 with the Thumb bit clear; CFSR reports `INVSTATE`, not the
`IMPRECISERR` the pre-naked-handler build appeared to show. **Why it matters.**
The old handler had printed `R2` as the PC, which looked like "PC in RAM"; the
naked handler fixed that, and the decoder now refuses to name a symbol for
`PC=0`. This is the case where a plausible-looking location would have been
worse than no location. **How to fix it.** Check the function pointer before the
call; LR still identifies the call site that made the jump.

### QEMU — clean regression (`tuck sim tests/metal/irq_marker.tuck`)

```
IRQ_MARKER_OK
qemu exit: 124   (124 = clean run into idle loop)
sim rc=0
```

**What happened.** The `--debug-lines` / decoder changes did not disturb the
clean path: the program prints its success marker and `tuck sim` exits 0.
**Why it matters.** The decoder is opt-in and post-mortem; it must never change
the behaviour of a healthy run. **How to fix it.** Nothing — this is the gate
that proves the other two outputs are faults, not a broken simulator.

## 7b. Supporting layer G — `tuck sim --host` (three targets)

```
$ ./tuck sim tests/metal/task_await.tuck --host
=== nim: build ===  ...  === nim: run ===  ENTER / TASK_OK  nim exit: 0
=== odin: build === ...  === odin: run === ENTER / TASK_OK  odin exit: 0
=== d: build ===    ...  === d: run ===    ENTER / TASK_OK  d exit: 0
=== three-target summary: PASS ===
```

stage5 (two stackless tasks driving the HAL) was checked the same way: 20
lines of interleaved LED output, byte-identical on all three backends.

**What happened.** `tuck sim --host` used to be a manual recipe: pick a stage,
hope the host build linked, read the output, repeat for the next backend. The
first host `tuck b` failed at link with `undefined reference to
tuck_semihost_write`, because the single Nim print shim imported the metal
semihosting symbol unconditionally. The shims also existed for Nim only —
the Odin import pointed at an empty directory and D looked for a `print_shim.d`
that was not there.

**Why it matters.** A cross-backend difference in a scheduler is a real bug,
not a toolchain curiosity — the same AST is lowered three times, and only a
side-by-side run shows when one lowering loses a yield or reorders an await.
Without the host loop, the only place all three backends met was the slow
end-to-end suite. Now the check is one command, and the fast loop tells you
*which* backend diverged because each run's stdout is labelled and separate.

**How to fix it / what was done.** `print_shim.nim` gates the semihosting import
on `defined(freestanding)`, so the QEMU path is unchanged and the host path
uses stdout. `print_shim` and `hal_shim` gained `.odin` and `.d` twins with the
same observable output; the Odin files share one `package host_sim` because
the emitted import names the directory, D imports each module by bare name.
`host-run.sh` runs all available backends (missing compiler = `SKIP`, not
failure) and `--backend:nim|odin|d` selects one. `tests/suites/sim_host.nim`
pins both stages and compares the captured program output byte-for-byte.
Note `--target:` is *not* the backend switch — it selects `when TARGET` platform
blocks; `--backend:` is the new flag.

**Verified.** All nine `sim_host` assertions pass in full mode; the QEMU
regressions (stage16 fault, stage14 null branch, stage11 clean run) still
report `rc=1 / 1 / 0` with the same decoded locations after the shared shim
edit.

## 7c. Supporting layer E/G — source-level breakpoints (T16, host half)

```
$ gdb -q -batch -ex 'set debuginfod enabled off' \
      -ex 'break tests/metal/task_await.tuck:10' \
      -ex run -ex bt --args /tmp/opencode/dbg/task_await
Breakpoint 1 at 0x12ad5: task_await.tuck:10. (2 locations)
Breakpoint 1.2, ...main_E () at tests/metal/task_await.tuck:10
#0  ...main_E () at tests/metal/task_await.tuck:10
```

**What happened.** A host binary built with the *already existing* flags
`--debug-lines --nim:"--passC:-g"` stops on a breakpoint set by `.tuck` file
and line; the backtrace names the `.tuck`, not the generated `.nim`. The
`tuck sim` ELF likewise carries `.debug_info` / `.debug_abbrev` / `.debug_line`,
and `objdump --dwarf=decodedline` names `task_await.tuck:6` at `0x99a`.
The new assertion in `tests/suites/crash_decode.nim` pins the host half (13/13
pass) and reports SKIP where gdb is absent.

**Why it matters.** This is the last unverified claim in the "explain my crash"
story: T6 decodes a fault after the fact, but a developer also needs to stop a
healthy program on a line they wrote. It costs no new CLI surface — the gap was
documentation and a pinned recipe, not a missing feature. It also bounds T16
honestly: the compiler's DWARF half is done; the *metal* half is blocked by the
absence of an ARM gdb, not by Tuck.

**How to fix it / what was done.** Added the recipe to T16 in the plan with the
evidence above; pinned the batch-gdb flow with `debuginfod` disabled (no CI
prompt) in a private output dir (the pool runs the addr2line build in parallel,
so sharing its `out/` was a race — the first run correctly failed with "out/t:
No such file or directory"). To finish T16: install `gdb-multiarch` or
`arm-none-eabi-gdb`, launch `qemu-system-arm -s -S -kernel ELF`, and point the
same script at `:1234`.

## 7d. Supporting layer B — the coarse timing score (T11)

```
$ ./tuck timing /tmp/opencode/costprobe.tuck
Worst-case cycles (coarse static estimate; report only):
  ~162 cyc  main()  (costprobe.tuck:22)
  ~125 cyc  big()   (costprobe.tuck:10)
  ~37 cyc  small()  (costprobe.tuck:4)
  ~27 cyc  dyn({n: int})  (costprobe.tuck:16)  [not a hard bound]
           loop bound not provable; body counted once
```

**What happened.** A new `compiler/cost_model.nim` scores one `Decl` from the
checked AST: a small weight per `ExprKind` (all 56 named, no silent default),
worst arm for `if`/`match`, callee score through `calleeDecl`, and a loop body
multiplied by its trip count when BOTH ends of a `..`/`..<` range constant-fold.
A parameter bound or an `exkWhile` gets a note, not a guessed number. IO calls
are noted as unmodelled. `tuck timing` prints the result in text and JSON
(`cost[].cyclesApprox`, `exact`, `notes`) with an explicit "report only" banner.

**Why it matters.** This is the answer to "how do we guess timings?": not Big-O
and not a measured trace, but an arithmetic upper bound over the actual AST.
It gives the developer a pre-flash answer to "did this edit double the worst
path?" before any hardware exists, and it is honest about where it stops. That
honesty is the difference between a useful budget flag and a number someone
mistakes for a proof.

**How to fix it / what was done.** The budget seam the owner asked for is in
`scoreDecl(res, m, d, budgets)`: budgets are keyed by `Decl.id`, so `deadline:`
parsing can fill the table later without touching the scorer. A declared cap
becomes the caller-visible cost (`max(estimate, budget)`), and an estimate over
the cap appends a note rather than being clamped away — verified directly:
plain 3 -> cap 40 gives 40; cap 2 gives 3 plus "exceeds declared max 2". The
complexity ratchet caught the first cut: `renderText` crossed cc=15, so the new
section moved into `renderCostText` rather than raising the gate. `tests/suites/
timing_report.nim` now pins call-path accumulation, constant-loop scaling,
worst-arm branch symmetry, unprovable-loop notes, and IO notes (21/21 pass).

## 7e. T7 finished — SysTick guest clock, tick length, and a second board (2026-11-21)

```
$ ./tuck sim tests/metal/clock_advances.tuck --tick:0
...
=== qemu run (10s, board=lm3s6965evb, -icount shift=0,sleep=off) ===
CLOCK_OK
qemu exit: 124   (124 = clean run into idle loop)

$ TUCK_BOARD=stm32vldiscovery ./tuck sim tests/metal/clock_advances.tuck --tick:10
...
=== qemu run (10s, board=stm32vldiscovery, -icount shift=10,sleep=off) ===
CLOCK_OK
qemu exit: 124
```

**What happened.** QEMU 8.2 does not emulate DWT (`0xE0001004` reads zero), so
the reusable `systick_clock.tuck` reads SysTick's 24-bit down-counter instead:
`clock_init(reload)`, `clock_now() -> u32`, wrap-safe `clock_elapsed`. QEMU's
ptimer uses `PTIMER_POLICY_NO_IMMEDIATE_RELOAD` — writing `CVR` clears it and the
first reload is one edge later — so `clock_init` burns 1000 reads to warm the
counter. `--tick:N` (0..10) now drives `-icount shift=N,sleep=off` (each step
doubles virtual ns per instruction); `--time:fast` is the shift-10 preset.

**Two boards, one loop.** `TUCK_BOARD` selects the QEMU machine, CPU, linker
script and initial SP. Adding `stm32vldiscovery` (128K flash/8K SRAM, SP
`0x20002000`) exposed three real metal bugs, each found by reading the fault
record rather than guessing:
1. the C `__aeabi_read_tp` clobbered r3, which Nim's generated TLS access keeps
   the GOT offset in across the call — every error-flag/overflow-trap read
   faulted at `BFAR=40001c78`. Moved the accessor to `semihost.s` (EABI: only
   r0 may change) and made `tuck_tls` a global there.
2. `tuckOverflowTrap` formatted a string through the freestanding `appendString`
   magic; under `-d:freestanding` it now discards `ty`/`op` and just `quit(1)`.
3. QEMU's `stm32vldiscovery` loader does not initialise a RAM load segment, so
   the GOT was set from garbage; the linker script copies `.got` with `.data`.

**Verification.** Both boards print `CLOCK_OK` and fall into the idle loop
(`qemu exit: 124`) at shifts 0, 4 and 10. `boot_led_svd` and
`irq_marker` still boot cleanly on `stm32vldiscovery` and `lm3s6965evb`
respectively (no regression). `tests/suites/sim_tick.nim` pins the four
`--tick` rejections and one scenario per board, SKIPping cleanly without QEMU /
the ARM toolchain / picolibc. The loop script gained `TUCK_SKIP_TUCK_BUILD` and
`TUCK_OUT_DIR` so parallel scenarios do not rebuild `tuck` or share an ELF.

**Deferred.** Higher-end boards (Cortex-M4 `mps2-an386`, M7 `mps2-an500`) need
fresh startup/linker/semihost wiring and a machine map; staged until a feature
needs their peripherals. A real `tuck profile` should prefer DWT on hardware
and fall back to SysTick under emulation — blocked on T5's CTF/egress decision.

## 7f. Review pass — failures that looked like success (2026-11-22)

```
$ ./tuck sim tests/metal/panic_bounds.tuck
PANIC: index out of bounds
FAULT PC=000004e2 LR=0000031d CFSR=00010000 HFSR=40000000 ...
qemu exit: 1
  What: A runtime check failed and stopped the program (the PANIC line names it).
  LR 0000031D -> ...pick... (call site .../panic_bounds.tuck:9)
```

**What happened.** The same program used to print `BEFORE` and nothing else,
and `tuck sim` exited 0: Tuck's freestanding bounds check spun in
`while true`, the loop's 10 s timeout ended QEMU with 124, and 124 meant
"clean". Heap exhaustion was worse: 200 spawned tasks, zero ran, exit clean.
**Why it matters.** On metal, a test that cannot fail is the most expensive
kind: it ships. Every green QEMU line before this pass was "it printed its
marker", never "it did not do something else afterwards". **How it was
fixed.** One board hook per outcome: `tuck_board_exit(rc)` ends QEMU with
main's return value, and `tuck_fatal(msg)` prints `PANIC:` and traps with
LR set to the failing check's caller, so the existing fault recorder and
decoder name the Tuck line (`addr2line -i`, first `.tuck` frame). A timeout
is now reported as "still running", never success. The same pass fixed
`critical:` nesting and early exit (stage18), the ISR slot's lost words
(stage19) and the ISR audit's blind spot for tasks; `REVIEW-2026-11-22.md`
has the table and the still-open list.

## 8. Metal lane — depends on picolibc (step 0 of the vision)

After a Thumb libc links, the runtime layers become possible:
- event ring: fixed `pool`-backed records, word-writes only, instrumenting
  stage fns, sends, and ISR entry/exit; export CTF through layer A;
- compiler-generated HardFault handler + ELF-note crash dump;
- `tuck decode-crash` mapping PC→Tuck line through DWARF (verify early, vision
  §8.1 #2), emitting SARIF + Markdown through layer A;
- virtual-time QEMU replay and fault injection, including widen-the-window.

## 9. First vertical slice (the disciplined way in)

Do **one** end-to-end slice before any of the rest:

1. Pin a torn-counter bug in `known_bugs.nim` (`bugOpen`).
2. Add `[irq]` context marker + `isr` fact over call edges.
3. Build the shared-access table; `tuck audit --isr` reports the two writers
   through layer A (JSON + SARIF). Suite asserts the report names both sites.
4. Flip the pin to `bugFixed` only when TK-EF10/11 reject it under
   `--isr-check:error`.
5. Re-emit nothing (no codegen change); run `tests/run` + the QEMU loop.

If this slice stays small, the remaining rules are repetitions of the same
mechanism — which is the whole point of building the supporting layers first.

## 9a. Progress (2026-11-19)

- **Slice 1** — `[irq]` context marker; one-shot combination diagnostics. ✅
- **Slice 2** — `tuck audit FILE --isr`: signature-keyed display, id-keyed
  identity, shared-state inventory with source locations and a what/why/fix
  explanation. ✅ (QEMU + `isr_discipline` suite)
- **Slice 3** — TK-EF10 gate under `--isr-check:error`, opt-in; clean
  `file:line:col` diagnostic naming both contexts. ✅ (QEMU: default build
  boots, gated build refused)
- **Slice 4** — `critical:` as its own AST node kind; Nim/Odin/D codegen emit a
  critical-enter/exit pair (CPSID/CPSIE on freestanding); the audit marks
  protected accesses and the gate fires only for unprotected ones. ✅ (QEMU:
  `critical_shared` boots and prints `CRITICAL_OK`)

**Slice 5** — TK-EF11 refuses I/O, blocking waits and allocation inside a
`critical:` block, with a diagnostic naming the block and the fix. ✅ (QEMU
re-verified, `isr_discipline` suite)

**Slice 6** — shared reporter layer: `tuck audit --isr --format:json|sarif`
emits jq-friendly JSON and standard SARIF 2.1.0, with TK-EF10 as the rule id.
✅ (parsed with python json; pinned in the suite)

**Slice 7** — ISR-safe SPSC handoff: the runtime exposes a preallocated
single-slot `tuckIsrPost` / `tuckIsrTake` pair (volatile flag + DMB on metal,
no lock, no allocation). An ISR posts a word through it without violating
TK-EF07. `isr_handoff` boots under QEMU and prints ISR_SPSC_OK. The slot
is a raw 0..15 index today; named/declared slots are a future refinement.

This slice completes the ISR-discipline vertical slice.

**Slice 8** — Event ring: a fixed 256-entry ring in `tuck_sl` records task
switches (ready/run) and ISR posts with one word write each (no formatting on
the hot path). `tuckEventDump` reports the count over semihosting.
`task_fire_forget` prints `DUMP-ENTER HEAD=2 DUMP-DONE` then `WORKER WORKER`
under QEMU.

**Two traps hit while building these slices (worth remembering):**

1. **Stale incremental Nim cache.** After adding enum entries to
   `compiler/diagnostics.nim`, `nim c -o:tuck tuck.nim` reused stale objects and
   every diagnostic code shifted (`TK-RG01` came out as `TK-IV01`) until
   `rm -rf ~/.cache/nim/tuck_d` forced a clean rebuild. After ANY enum change,
   wipe that cache before trusting a test result.
2. **Freestanding edits inside a hosted-only section.** I changed
   `opened*: MonoTime` to `int64` in `tuck_rt_stdlib_externs.nim` while making
   the freestanding build compile — but that whole file is included only when
   NOT freestanding, so the change broke `--actors:batch` on hosted builds and
   was invisible to `--quick`. Ask "which builds actually include this code?"
   before editing a shared runtime file for a freestanding problem.

## 10. Scope discipline

- No general RTOS: actors + tasks + the deterministic stackless scheduler are
  the concurrency model.
- No GUI: one CLI plus editor integration.
- No hard WCET gate on day one: report, then opt-in.
- No new node kinds except where the invariant demands them (`exkCritical`);
  prefer extending the facts/effects layer for everything else.
