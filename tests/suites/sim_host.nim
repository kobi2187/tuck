## `tuck sim --host` — the fastest embedded loop, on all three backends.
##
## A host run cannot prove anything about MMIO or interrupts; that is what the
## QEMU loop is for. It CAN prove the logic and the scheduler describe the same
## program on Nim, Odin and D. This suite pins the developer-facing promise:
## one command builds and runs a stage against the shared host shims, and the
## observable stdout is byte-identical across all three backends. A backend
## compiler missing from PATH is SKIP, never FAIL.

import std/[os, strutils, tables]
import ../harness

proc programOut(text, be: string): string =
  ## Drop the build banners (which necessarily differ per compiler) and keep
  ## only what the program wrote between `=== be: run ===` and `be exit:`.
  var collecting = false
  for line in text.splitLines():
    if line == "=== " & be & ": run ===":
      collecting = true
      continue
    if line.startsWith(be & " exit: "):
      break
    if collecting:
      result.add line & "\n"

proc simBackend(t: var T, name, stage, be: string,
                want: seq[string]): string =
  let exe = t.root / "tuck"
  let idx = t.needCmd(@[exe, "sim", stage, "--host", "--backend:" & be], vBuild)
  if t.phase == pCollect: return ""
  if t.skippedCmd(idx): t.skip name; return ""
  let (rc, text) = t.resultOf(idx)
  if rc != 0:
    t.no name, "tuck sim --host failed: " & text
    return ""
  if text.contains("SKIP " & be & ": compiler not found"):
    # The suite's promise above: a missing compiler is SKIP, never FAIL.
    t.skip name
    return ""
  if text.contains("!!!") or text.contains("SKIP"):
    t.no name, "backend did not run: " & text
    return ""
  let captured = programOut(text, be)
  if captured == "":
    t.no name, "no program output captured: " & text
    return ""
  for w in want:
    if not captured.contains(w):
      t.no name, "expected " & w & " in: " & captured
      return ""
  t.ok name
  captured

proc sameOutput(t: var T, name: string, got: Table[string, string]) =
  if t.phase == pCollect: return
  if got["nim"] == "" or got["odin"] == "" or got["d"] == "":
    t.skip name
    return
  for be in @["odin", "d"]:
    if got[be] != got["nim"]:
      t.no name, be & " differed from nim:\n" & got[be] & "--- nim ---\n" &
        got["nim"]
      return
  t.ok name

proc run*(t: var T) =
  let exe = t.root / "tuck"
  let stage9 = t.root / "testing_experiment" / "stage9_minimal_task.tuck"
  let stage5 = t.root / "testing_experiment" / "stage5_stackless_blink.tuck"
  let backends = @["nim", "odin", "d"]

  # --- stage 9: a task and the print shim ---------------------------------
  var got9: Table[string, string]
  for be in backends:
    got9[be] = t.simBackend("stage9 runs on " & be, stage9, be,
                            @["ENTER", "TASK_OK"])
  t.sameOutput "stage9 output is byte-identical on all three backends", got9

  # --- stage 5: two stackless tasks through the HAL shim ------------------
  var got5: Table[string, string]
  for be in backends:
    got5[be] = t.simBackend("stage5 runs on " & be, stage5, be,
                            @["LED 1 ON", "LED 0 ON", "LED 1 OFF"])
  t.sameOutput "stage5 scheduler output is byte-identical on all three", got5

  # A bogus backend name is rejected at the CLI, before any build starts.
  let bad = t.needCmd(@[exe, "sim", stage9, "--host", "--backend:zig"])
  if t.phase != pCollect:
    let (rc, text) = t.resultOf(bad)
    if rc != 0 and text.contains("unknown --backend:zig"):
      t.ok "an unknown backend is rejected before building"
    else:
      t.no "an unknown backend is rejected before building", text

  t.finish()
