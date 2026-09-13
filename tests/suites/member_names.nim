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

  # A member fn and a top-level fn may share a name, and a call that NAMES
  # the fn reaches the top-level one (issue #19).
  #
  # Fixed by identity, not by name. `topLevelFns` is a HashSet of NAMES, and
  # topLevelDeclOfFn asked `d.name in tc.topLevelFns` of each candidate —
  # which is true of BOTH decls when they share a name, so it returned
  # whichever `fnDecls` happened to list first. The top-level decl is now
  # recorded as itself (topLevelFnDecl) and returned directly.
  #
  # DECLARATION ORDER IS THE POINT. The object comes first here on purpose:
  # with the top-level fn first the old code passed by luck, which is how
  # this sat marked fixed while the reversed order still failed. Same
  # order-dependence family as the group-conformance bug (#38).
  t.src """
object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1

fn noise({n: int}) -> int:
  return n + 1

fn main() -> int:
  return {n: 41} noise
"""
  t.okCheck "a member fn and a top-level fn may share a name"
  t.runs "...and a call naming it reaches the TOP-LEVEL one", 42
  t.hostBuilds "...on every backend"
  t.bugFixed "member fn shadows a top-level fn of the same name"

  # ...and the other order, which passed even while the bug was open.
  t.src """
fn noise({n: int}) -> int:
  return n + 1

object Dog:
  name: str
  fn noise({self: Dog}) -> int:
    return 1

fn main() -> int:
  return {n: 41} noise
"""
  t.runs "...whichever order the two are declared in", 42

  # Writing the payload on the WRONG SIDE of a member call used to report
  # "missing required field 'self: Bx' (add it, or alias a field to that
  # name)" — advice that cannot be followed, since a receiver is not something
  # you pass in the payload, and which never named the form that works. It now
  # says which type declares the fn and shows the shape.
  t.src """
object Bx:
  n: int
  fn grow({self: Bx, count: int}) -> int:
    return count

fn main() -> int:
  var b = {n: 1} Bx
  return {count: 7} b.grow
"""
  t.badCheck "a payload on the wrong side names the type that declares the fn",
             "declared\\ inside\\ Bx"
  t.badCheck "...and shows the receiver form", "<a\\ Bx>\\.grow"

  # ...and the RIGHT side still works, which is the form being pointed at.
  t.src """
object Bx:
  n: int
  fn grow({self: Bx, count: int}) -> int:
    return count

fn main() -> int:
  var b = {n: 1} Bx
  return b.grow {count: 7}
"""
  t.runs "...and the form it points at is the one that works", 7

  # An ordinary missing field is NOT a receiver mistake and keeps the original
  # advice — the hint must not swallow the common case.
  t.src """
fn grow({count: int, label: str}) -> int:
  return count

fn main() -> int:
  return {count: 7} grow
"""
  t.badCheck "an ordinary missing field keeps the alias advice",
             "alias\\ a\\ field\\ to\\ that\\ name"

  t.finish()
