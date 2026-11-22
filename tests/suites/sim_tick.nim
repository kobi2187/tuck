## `tuck sim --tick:` validation and the QEMU scenario coverage it enables.
##
## The tick shift is parsed and range-checked in the CLI *before* any toolchain
## runs, so the rejection cases here are milliseconds and need neither QEMU nor
## the ARM cross toolchain. The scenario cases boot the SysTick clock fixture
## under QEMU on both supported boards; they SKIP cleanly when QEMU or the ARM
## toolchain (or the vendored picolibc) is absent.
##
## Board profile and tick length together decide the QEMU `-icount` and `-M`
## arguments, so one case per board exercises both halfs of the plumbing.

import std/[os, strutils]
import ../harness

proc rejection(t: var T, name, flag, want: string) =
  let exe = t.root / "tuck"
  let stage = t.root / "testing_experiment" / "stage17_clock.tuck"
  let idx = t.needCmd(@[exe, "sim", stage, flag], vCheck)
  if t.phase == pCollect: return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = t.resultOf(idx)
  if rc != 0 and text.contains(want):
    t.ok name
  else:
    t.no name, "expected rc!=0 and '" & want & "', got rc=" & $rc & ": " & text

proc scenario(t: var T, name, board, tick, slot, want: string) =
  let exe = t.root / "tuck"
  let stage = t.root / "testing_experiment" / "stage17_clock.tuck"
  # `tuck sim --tick:N` sets TUCK_ICOUNT_SHIFT itself. The harness passes the
  # board plus a private scratch dir (so parallel scenarios cannot clobber
  # each other's ELF) and skips the loop's redundant tuck rebuild — stage 1 of
  # the runner already produced the binary under test.
  let argv = @["env", "TUCK_BOARD=" & board,
               "TUCK_OUT_DIR=/tmp/scratchpad/tuck-sim-tick-" & slot,
               "TUCK_SKIP_TUCK_BUILD=1",
               exe, "sim", stage, "--tick:" & tick]
  let idx = t.needCmd(argv, vRun)
  let metalReady = findExe("qemu-system-arm") != "" and
                   findExe("arm-none-eabi-gcc") != "" and
                   dirExists(t.root / "testing_experiment" / "build" /
                             "picolibc" / "install")
  if t.phase == pCollect:
    # Retire the work item up front when the metal tools are missing, so a
    # machine without QEMU pays neither a pointless tuck rebuild nor a timeout.
    if not metalReady: t.work[idx].skipped = true
    return
  if t.skippedCmd(idx): t.skip name; return
  let (rc, text) = t.resultOf(idx)
  if rc == 0 and text.contains(want) and text.contains("qemu exit: 0"):
    t.ok name
  else:
    t.no name, "expected a clean run printing '" & want &
      "', got rc=" & $rc & ": " & text

proc run*(t: var T) =
  # Fast CLI validation — no QEMU, no build.
  t.rejection "--tick:11 is rejected", "--tick:11", "needs 0..10, got 11"
  t.rejection "--tick:-1 is rejected", "--tick:-1", "needs 0..10, got -1"
  t.rejection "--tick:abc is rejected", "--tick:abc", "needs 0..10, got abc"
  t.rejection "--tick: with no number is rejected", "--tick:", "needs 0..10"

  # One tick shift per supported board: lm3s at the finest tick, the STM32
  # board at the coarsest. Both must print the clock marker and exit 0 through
  # semihosting (qemu exit: 0; 124 would be a timeout), proving the tick flag
  # and board profile reach QEMU rather than merely parsing.
  t.scenario "clock at tick 0 on lm3s6965evb", "lm3s6965evb", "0", "lm3s",
             "CLOCK_OK"
  t.scenario "clock at tick 10 on stm32vldiscovery", "stm32vldiscovery", "10",
             "stm32", "CLOCK_OK"

  t.finish()
