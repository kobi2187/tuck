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

- **On metal**, `boards/startup_lm3s6965evb.c` prints one parseable
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

### QEMU — precise fault (`tuck sim testing_experiment/stage16_precise_fault.tuck`)

```
FAULT PC=0000015a LR=00000185 CFSR=01000000 HFSR=40000000 BFAR=00000000 xPSR=01000000
...
=== decoded crash ===
Crash: UsageFault (CFSR=0x01000000, HFSR=0x40000000)
  bit: UNALIGNED: unaligned word load/store (CCR.UNALIGN_TRP)
  bit: FORCED: a Mem/Bus/Usage fault escalated to HardFault
  What: UNALIGNED: unaligned word load/store (CCR.UNALIGN_TRP); escalated to HardFault because its handler was not enabled
  PC 0000015A -> preciseFaultStore_u0__...fault95shim (host_sim/fault_shim.nim:22)
  LR 00000185 -> tuckXCBX91fnXCBX91main__u0__stage1695precise95fault (call site stage16_precise_fault.tuck:19)
  Why: The stacked PC points at the failing instruction, so a source line can be recovered from DWARF built with --debug-lines.
  Fix: Align the address to 4 bytes, or use a byte/halfword access. Cortex-M traps unaligned word accesses when CCR.UNALIGN_TRP is set.
sim rc=1
```

**What happened.** A directly-called shim did an unaligned word store; the core
raised a *precise* UsageFault and the stacked PC names the faulting instruction.
**Why it matters.** PC and LR agree on one call chain, so the report can name
both the failing machine address and the Tuck line that led there — the developer
edits `stage16_precise_fault.tuck:19`, not a generated `.nim`. **How to fix it.**
Align the store or use byte/halfword accesses; the report says exactly that.
`sim` exits 1 because a FAULT line was present.

### QEMU — null branch (`tuck sim testing_experiment/stage14_fault.tuck`)

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

### QEMU — clean regression (`tuck sim testing_experiment/stage11_irq_marker.tuck`)

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
  `stage12_critical` boots and prints `CRITICAL_OK`)

**Slice 5** — TK-EF11 refuses I/O, blocking waits and allocation inside a
`critical:` block, with a diagnostic naming the block and the fix. ✅ (QEMU
re-verified, `isr_discipline` suite)

**Slice 6** — shared reporter layer: `tuck audit --isr --format:json|sarif`
emits jq-friendly JSON and standard SARIF 2.1.0, with TK-EF10 as the rule id.
✅ (parsed with python json; pinned in the suite)

**Slice 7** — ISR-safe SPSC handoff: the runtime exposes a preallocated
single-slot `tuckIsrPost` / `tuckIsrTake` pair (volatile flag + DMB on metal,
no lock, no allocation). An ISR posts a word through it without violating
TK-EF07. `stage13_isr_spsc` boots under QEMU and prints ISR_SPSC_OK. The slot
is a raw 0..15 index today; named/declared slots are a future refinement.

This slice completes the ISR-discipline vertical slice.

**Slice 8** — Event ring: a fixed 256-entry ring in `tuck_sl` records task
switches (ready/run) and ISR posts with one word write each (no formatting on
the hot path). `tuckEventDump` reports the count over semihosting.
`stage10_fire_forget` prints `DUMP-ENTER HEAD=2 DUMP-DONE` then `WORKER WORKER`
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
