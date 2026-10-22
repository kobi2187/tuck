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
  ("core", "error", "error"), ("core", "fmt", "fmt"), ("core", "geom", "geom"), ("core", "hash", "hash"), ("core", "iter", "iter"), ("core", "num", "num"), ("core", "types", "types"), ("std", "math", "math"), ("std", "chrono", "chrono"), ("std", "i18n", "i18n"), ("platform", "boot", "boot"), ("platform", "power", "power"), ("sys", "env", "env"), ("std", "perf", "perf"), ("std", "queue", "queue"), ("std", "testing", "testing"), ("std", "crypto", "crypto"), ("std", "encoding", "encoding"), ("std", "log", "log"), ("std", "regex", "regex"), ("std", "net-http", "http"), ("platform", "dsp", "dsp"), ("platform", "watchdog", "watchdog"), ("sys", "process", "process"), ("std", "cli", "cli"), ("std", "compress", "compress"), ("std", "archive", "archive"), ("std", "random", "random"), ("sys", "path", "path"), ("sys", "files", "files"), ("sys", "time", "clock"), ("sys", "io", "stream"), ("sys", "net", "socket"), ("sys", "signal", "signal"), ("sys", "mmap", "mmap"), ("platform", "libc-shim", "board"), ("platform", "hal", "hal"), ("platform", "devicetree", "devicetree"), ("platform", "net-lowpower", "advertise"),
  ("core", "str", "text")]

proc stdlibArg(t: T): string =
  "--stdlib:stdlib-project"

proc tuckAbs(t: T): string = absolutePath(tuckExe)

proc moduleScript(t: T, tier, dirName, name: string, backend: string): string =
  ## Copy the module to its own directory, build it against the project
  ## stdlib, run it: the module's exit code is the script's. `backend` is
  ## "", "odin" or "dlang".
  let dir = t.curDir / name & (if backend == "": "" else: "-" & backend)
  let src = t.root / "stdlib-project" / "modules" / tier / dirName / name & ".tuck"
  let (flag, bin) = case backend
                    of "odin": ("--odin ", "m_odin")
                    of "dlang": ("--dlang ", "m_d")
                    else: ("", "m")
  # dmd may live outside PATH (the harness knows where); the driver needs it on it.
  let dmdPath = if backend == "dlang": "PATH=" & parentDir(findDmd()) & ":$PATH " else: ""
  # A module's `impl:` shims sit in its own `shim/` folder, beside it.
  let shims = src.parentDir / "shim"
  let copyShims = if dirExists(shims): " && cp -r " & shims & " " & dir else: ""
  "mkdir -p " & dir & " && cp " & src & " " & dir / "m.tuck" & copyShims & " && cd " & dir &
    " && " & dmdPath & tuckAbs(t) & " b m.tuck " & flag &
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
  var nim, odin, dlang: seq[(string, int)]
  let haveD = findDmd().len > 0
  for (tier, dirName, name) in Modules:
    nim.add (name, t.needCmd(@["sh", "-c", moduleScript(t, tier, dirName, name, "")], verb = vRun))
    odin.add (name, t.needCmd(@["sh", "-c", moduleScript(t, tier, dirName, name, "odin")], verb = vRun))
    if haveD:
      dlang.add (name, t.needCmd(@["sh", "-c", moduleScript(t, tier, dirName, name, "dlang")], verb = vRun))
  if t.phase != pCollect:
    for (label, runs) in [("Nim", nim), ("Odin", odin), ("D", dlang)]:
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

  # An IMPORTED module whose externs live in per-backend shims (sys.mmap): the
  # shims are found beside the module, not beside the program (A82).
  t.addFile "mapuse.tuck", """
import mmap
import fs

fn main() -> int [io: fs]:
  let w = {path: "/tmp/tuck-mapuse.txt", content: "a\nb\nc\n"} writeFile
  if not w.ok:
    return 1
  let m = {path: "/tmp/tuck-mapuse.txt"} mapFile
  if not m.ok:
    return 2
  let n = {m: m.value} lineCount
  {m: m.value} unmapFile
  return n
"""
  var mapRuns: seq[(string, int)]
  for (label, flag, bin) in [("Nim", "", "mapuse"), ("Odin", "--odin", "mapuse_odin"),
                             ("D", "--dlang", "mapuse_d")]:
    if label == "D" and not haveD: continue
    let dir = t.curDir / ("mapuse-" & label)
    let dmdPath = if label == "D": "PATH=" & parentDir(findDmd()) & ":$PATH " else: ""
    mapRuns.add (label, t.needCmd(@["sh", "-c", "mkdir -p " & dir & " && cp " &
        t.curDir / "mapuse.tuck" & " " & dir & " && cd " & dir & " && " & dmdPath &
        tuckAbs(t) & " b mapuse.tuck " & flag & " " & stdlibArg(t) & " --root:" &
        t.root & " > build.log 2>&1 && ./" & bin], verb = vRun))
  if t.phase != pCollect:
    for (label, idx) in mapRuns:
      let title = "an imported module's impl shims are found on " & label
      if t.skippedCmd(idx): t.skip title; continue
      let (rc, outp) = t.resultOf(idx)
      if rc == 3: t.ok title
      else: t.no title, "exit " & $rc & "\n" & outp

  t.finish()
