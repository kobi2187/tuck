## #199: wherever `stdlib-project` shadows a blessed `std/` module, it offers
## every name `std/` does, so a program moves between `--stdlib` choices
## unchanged. Names only (file reading, every mode); the payload shapes are
## held by each module's own checks. A name listed in `Different` is a known,
## recorded divergence with its reason, not a quiet one.

import std/[os, strutils, sets]
import ../harness

const Different = [
  # module, name, why
  ("random", "step", "std: record in, record out; project: u64 out (Dice type)"),
  ("random", "rollRange", "std: record threaded; project: Dice in, RolledInt? out"),
  ("random", "draw32", "project spells it nextU32 over a Dice value"),
  ("random", "draw64", "project has no 64-bit draw yet"),
  ("random", "pcgMult", "project spells it lcgMultiplier"),
  ("random", "osSeed", "project declares it as an extern of its own")]

proc fnNames(path: string): HashSet[string] =
  for line in lines(path):
    let l = line.strip()
    if l.startsWith("fn "):
      var n = ""
      for c in l[3 .. ^1]:
        if c.isAlphaNumeric or c == '_': n.add c
        else: break
      result.incl n

proc run*(t: var T) =
  let blessed = t.root / "std"
  var found = false
  for path in walkFiles(blessed / "*.tuck"):
    let name = splitFile(path).name
    var project = ""
    for p in walkDirRec(t.root / "stdlib-project" / "modules"):
      if p.endsWith("/" & name & ".tuck") and "/shim/" notin p: project = p
    if project == "": continue
    found = true
    let have = fnNames(project)
    var missing: seq[string]
    for n in fnNames(path):
      var excused = false
      for d in Different:
        if d[0] == name and d[1] == n: excused = true
      if n notin have and not excused: missing.add n
    if missing.len == 0: t.ok "stdlib-project/" & name & " offers every std/" & name & " name"
    else: t.no "stdlib-project/" & name & " offers every std/" & name & " name",
               "missing: " & missing.join(", ")
  if not found: t.no "some shadowed std/ module was compared", "none found"
  t.finish()
