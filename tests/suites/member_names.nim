## Two objects may declare a member fn of the same name.
##
## `Dog.noise` and `Cat.noise` are different functions. Nim tolerated the clash
## because it overloads on the `self` parameter's type; Odin does not overload,
## so the emitted package had two `noise :: proc` at top level and failed with
## "Redeclaration of 'noise' in this scope".
##
## This is the shape interfaces exist for — several types answering the same
## call — so it has to work before dispatch can be built on it.

import std/[os, strutils]
import ../harness

proc run*(t: var T) =
  t.src """
object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1

object Cat:
  lives: int
  fn noise({self: Cat}) -> int:
    return 41

fn main() -> int:
  return 0
"""
  t.okCheck   "two objects may share a member fn name"
  t.emits     "Nim keeps them apart",  "tuck_Dog_noise|noise\\*\\(self: var tuck_Dog\\)"
  t.emitsOdin "Odin keeps them apart", "tuck_Dog_noise"

  # The real gate: the emitted Odin must COMPILE. Emission alone proved nothing
  # here — the old output looked plausible and only `odin build` rejected it.
  let odinExe = findOdin()
  let snippet = t.curDir
  let pkg = snippet / "odinpkg"
  var buildIdx = -1
  if odinExe.len > 0:
    # The package is assembled from the .odin the pool itself emits, so the
    # staging has to happen BETWEEN that emit and this build — which is what
    # needCmdAfter's prep hook is for.
    let emitIdx = t.needOdin()
    buildIdx = t.needCmdAfter(
      @[odinExe, "build", pkg, "-o:none", "-out:" & pkg / "prog"],
      emitIdx,
      proc (dir: string) = stageOdinPkg(pkg, snippet / "odin" / "t.odin"),
      snippet)

  if t.phase == pReport:
    if odinExe.len == 0:
      echo "  skip  odin not found"
    else:
      let (rc, outp) = t.resultOf(buildIdx)
      if rc == 0: t.ok "the emitted Odin compiles"
      else:
        var errs: seq[string]
        for l in outp.splitLines():
          if l.toLowerAscii.contains("error"): errs.add l
          if errs.len >= 2: break
        t.no "the emitted Odin compiles", errs.join("\n")

  # Three objects, same name, and each still calls its own.
  t.src """
object A:
  n: int
  fn size({self: A}) -> int:
    return 1

object B:
  n: int
  fn size({self: B}) -> int:
    return 2

object C:
  n: int
  fn size({self: C}) -> int:
    return 39

fn main() -> int:
  return 0
"""
  t.okCheck "three objects may share a member fn name"

  # OPEN: a member fn still collides with a TOP-LEVEL fn of the same name.
  #
  # This one is the CHECKER, not emission. collectSigs registers object members
  # under their bare name into the same flat fnSigs as top-level fns
  # (typecheck.nim — "keyed by name alone, no overloading"), so `Dog.noise`
  # overwrites the free `noise` and the call demands a `self`. Pools already show
  # the fix — they key qualified (`Pool.acquire`) — but applying it to members
  # means changing call resolution, not just emission, so it is its own change.
  t.src """
fn noise({n: int}) -> int:
  return n

object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1

fn main() -> int:
  return {n: 41} noise
"""
  t.quietly: t.okCheck("a member fn and a top-level fn may share a name")
  t.bugOpen "member fn shadows a top-level fn of the same name"

  t.finish()
