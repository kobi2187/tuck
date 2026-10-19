## `--stdlib:stdlib-project` (issue #105) and the modules it selects.
##
## Two halves. The flag: it shadows `std/` by module file name, it makes
## `when STDLIB == "NAME":` blocks compile in, and it refuses an unknown name.
## The modules: every `stdlib-project` module carries a `main` of its own
## checks, so each one is built and run on Nim and on Odin; an exit code other
## than 0 names the check that failed. Dogfooding means the stdlib is held to
## the same two backends as everything else, and what it finds is fixed in the
## compiler or the module, or recorded in `stdlib-project/ROADMAP.md`.

import std/[os, strutils]
import ../harness

const Modules = [
  ("alloc", "deque", "deque"), ("alloc", "list", "list"), ("alloc", "map", "map"),
  ("alloc", "set", "set"), ("alloc", "string", "string"), ("alloc", "vec", "vec"),
  ("core", "array", "array"), ("core", "cmp", "cmp"), ("core", "convert", "convert"),
  ("core", "hash", "hash"), ("core", "iter", "iter"), ("core", "num", "num"),
  ("core", "str", "text")]

proc stdlibArg(t: T): string =
  "--stdlib:stdlib-project"

proc tuckAbs(t: T): string = absolutePath(tuckExe)

proc moduleScript(t: T, tier, dirName, name: string, odin: bool): string =
  ## Copy the module to its own directory, build it against the project
  ## stdlib, run it: the module's exit code is the script's.
  let dir = t.curDir / name & (if odin: "-odin" else: "")
  let src = t.root / "stdlib-project" / "modules" / tier / dirName / name & ".tuck"
  let bin = if odin: "m_odin" else: "m"
  "mkdir -p " & dir & " && cp " & src & " " & dir / "m.tuck" & " && cd " & dir &
    " && " & tuckAbs(t) & " b m.tuck " & (if odin: "--odin " else: "") &
    stdlibArg(t) & " --root:" & t.root & " > build.log 2>&1 && ./" & bin

proc run*(t: var T) =
  t.src """
fn main() -> int:
  return 0
"""
  # --- the flag -------------------------------------------------------------
  t.addFile "trimmed.tuck", """
import text
import str

fn main() -> int [io]:
  let t = {t: "  hi  "} trim
  return {t: t} byteCount
"""
  # `trim` is core.str.text's; the blessed std/ has no module by that name that
  # offers it. Same file, two stdlibs, two answers.
  let withFlag = t.needCmd(@[tuckExe, "ch", t.curDir / "trimmed.tuck",
      stdlibArg(t), "--root:" & t.root])
  let without = t.needCmd(@[tuckExe, "ch", t.curDir / "trimmed.tuck",
      "--root:" & t.root])
  let unknown = t.needCmd(@[tuckExe, "ch", t.curDir / "trimmed.tuck",
      "--stdlib:no-such-stdlib", "--root:" & t.root])
  t.addFile "gated.tuck", """
when STDLIB == "stdlib-project":
  fn pick() -> int:
    return 7

when STDLIB == "other":
  fn pick() -> int:
    return 9

fn main() -> int:
  return pick
"""
  let gatedOn = t.needCmd(@["sh", "-c", tuckAbs(t) & " b " & t.curDir / "gated.tuck" &
      " -o:" & t.curDir / "gated-out " & stdlibArg(t) & " --root:" & t.root &
      " > /dev/null 2>&1; " & t.curDir / "gated-out" / "gated"], verb = vRun)
  if t.phase != pCollect:
    let (rc1, o1) = t.resultOf(withFlag)
    if rc1 == 0: t.ok "--stdlib selects the project's module: `trim` is found"
    else: t.no "--stdlib selects the project's module: `trim` is found", o1
    let (rc2, _) = t.resultOf(without)
    if rc2 != 0: t.ok "without the flag the blessed std/ is used: no `trim`"
    else: t.no "without the flag the blessed std/ is used: no `trim`", "checked OK"
    let (rc3, o3) = t.resultOf(unknown)
    if rc3 != 0 and "not found" in o3:
      t.ok "an unknown stdlib is refused, naming what was tried"
    else: t.no "an unknown stdlib is refused, naming what was tried", o3
    if t.skippedCmd(gatedOn): t.skip "`when STDLIB == \"NAME\":` compiles in only the chosen block"
    else:
      let (rc4, o4) = t.resultOf(gatedOn)
      if rc4 == 7: t.ok "`when STDLIB == \"NAME\":` compiles in only the chosen block"
      else: t.no "`when STDLIB == \"NAME\":` compiles in only the chosen block", $rc4 & " " & o4

  # --- the modules ----------------------------------------------------------
  var nim, odin: seq[(string, int)]
  for (tier, dirName, name) in Modules:
    nim.add (name, t.needCmd(@["sh", "-c", moduleScript(t, tier, dirName, name, false)], verb = vRun))
    odin.add (name, t.needCmd(@["sh", "-c", moduleScript(t, tier, dirName, name, true)], verb = vRun))
  if t.phase != pCollect:
    for (label, runs) in [("Nim", nim), ("Odin", odin)]:
      for (name, idx) in runs:
        let title = "stdlib-project " & name & "'s own checks pass on " & label
        if t.skippedCmd(idx): t.skip title; continue
        let (rc, outp) = t.resultOf(idx)
        if rc == 0: t.ok title
        else: t.no title, "exit " & $rc & "\n" & outp

  # --- the modules, used the way a program uses them -------------------------
  # Cross-module calls are where ownership has to be decided from a signature:
  # `split` takes its text by ownership, so a literal handed to it from another
  # module must arrive as an owned copy (it crashed on Odin when it did not).
  t.addFile "usage.tuck", """
import text
import convert
import seq

fn main() -> int [io]:
  let parts = {t: "10,20,x,,-5", at: ","} split
  var n = 0
  for p in parts:
    let v = {t: p} parseInt
    if v.ok:
      n = n + (v.value ^int)
    else:
      n = n + 1000
  return n
"""
  let useNim = t.needCmd(@["sh", "-c", tuckAbs(t) & " b " & t.curDir / "usage.tuck" &
      " -o:" & t.curDir / "usage-nim " & stdlibArg(t) & " --root:" & t.root &
      " > /dev/null 2>&1; " & t.curDir / "usage-nim" / "usage"], verb = vRun)
  let useOdin = t.needCmd(@["sh", "-c", "mkdir -p " & t.curDir / "usage-odin-src" &
      " && cp " & t.curDir / "usage.tuck" & " " & t.curDir / "usage-odin-src" &
      " && cd " & t.curDir / "usage-odin-src" & " && " & tuckAbs(t) &
      " b usage.tuck --odin " & stdlibArg(t) & " --root:" & t.root &
      " > build.log 2>&1 && ./usage_odin"], verb = vRun)
  if t.phase != pCollect:
    for (label, idx) in [("Nim", useNim), ("Odin", useOdin)]:
      let title = "split and parseInt compose across modules on " & label
      if t.skippedCmd(idx): t.skip title; continue
      let (rc, outp) = t.resultOf(idx)
      # 10 + 20 + 1000 (x) + 1000 (empty) - 5 = 2025, as an exit code: 233.
      if rc == 233: t.ok title
      else: t.no title, "exit " & $rc & "\n" & outp

  t.finish()
