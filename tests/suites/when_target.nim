## `when TARGET == "value":` — compile-time platform selection (spec §8.3).
## Was a fully speced, entirely unimplemented section (not even lexed past a
## dead `tkWhen` token) until this suite's sibling implementation landed:
## compiler/{ast,parser,modules}.nim + tuck.nim's `--target:NAME` flag.
##
## Needs needCmd/resultOf rather than okCheck/emits/etc.: those hardcode
## their `./tuck` argv with no way to pass --target: through.

import std/[os, strutils]
import ../harness

const src = """
when TARGET == "stm32f4":
  fn initClock() -> int:
    return 1

when TARGET == "rp2040":
  fn initClock() -> int:
    return 2

fn main() -> int:
  return initClock
"""

proc emittedFor(t: var T, target: string): string =
  ## Compile `src` with (or without, when target == "") --target:X, and
  ## return the emitted t.nim, "" on a failed emit.
  t.src src
  let outDir = t.curDir / ("out_" & (if target == "": "none" else: target))
  var argv = @["./tuck", "c", t.curDir / "t.tuck", "-o:" & outDir,
               "--root:" & t.root]
  if target != "": argv.add "--target:" & target
  let i = t.needCmd(argv)
  if t.phase == pCollect: return ""
  let (rc, outp) = t.resultOf(i)
  if rc != 0: return "EMIT FAILED: " & outp
  let p = outDir / "t.nim"
  if fileExists(p): readFile(p) else: ""

proc assertHasNotHas(t: var T, name, text, has, hasNot: string) =
  if t.phase == pCollect: return
  if text.startsWith("EMIT FAILED"):
    t.no name, text
  elif has in text and hasNot notin text:
    t.ok name
  else:
    t.no name, "got: " & text

proc run*(t: var T) =
  # --- selection picks the right block, drops the other entirely -----------

  let stm = t.emittedFor("stm32f4")
  t.assertHasNotHas("--target:stm32f4 emits only that block's body",
                     stm, "return 1", "return 2")

  let rp = t.emittedFor("rp2040")
  t.assertHasNotHas("--target:rp2040 emits only that block's body",
                     rp, "return 2", "return 1")

  let none = t.emittedFor("")
  if t.phase != pCollect:
    if "tuck_initClock" notin none:
      t.ok "no --target: both blocks are dropped, neither body is emitted"
    else:
      t.no "no --target: both blocks are dropped, neither body is emitted",
           "initClock was emitted with no --target given: " & none

  # A target matching nothing behaves the same as no target — checked by
  # emitted content, not `tuck ch`'s exit code: an undeclared `initClock`
  # still gradually type-checks either way (task_plan.md's "Unknown type for
  # undeclared symbols" note), so only the EMITTED code proves anything.
  let bogus = t.emittedFor("bogus-target")
  if t.phase != pCollect:
    if "tuck_initClock" notin bogus:
      t.ok "an unrecognised --target value drops every when block too"
    else:
      t.no "an unrecognised --target value drops every when block too",
           "initClock was emitted for a target that names no block: " & bogus

  # --- the Odin backend sees the same selection, no codegen changes needed -

  t.src src
  let odinDir = t.curDir / "out_odin_rp"
  let oi = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--odin",
                       "-o:" & odinDir, "--root:" & t.root,
                       "--target:rp2040"])
  if t.phase != pCollect:
    discard t.resultOf(oi)
    let odinOut = if fileExists(odinDir / "t.odin"): readFile(odinDir / "t.odin")
                  else: ""
    if "return 2" in odinOut and "return 1" notin odinOut:
      t.ok "the Odin backend resolves the same --target selection"
    else:
      t.no "the Odin backend resolves the same --target selection",
           "got: " & odinOut

  # --- only the one supported shape parses ----------------------------------

  t.src """
when FOO == "x":
  fn f() -> int:
    return 1

fn main() -> int:
  return 0
"""
  t.badCheck "'when' rejects anything but 'when TARGET == \"...\":'", "TARGET"

  t.finish()
