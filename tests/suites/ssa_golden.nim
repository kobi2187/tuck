## SSA GOLDENS — the graph for a set of small programs, pinned.
##
## `tests/ssa/NN-shape.tuck` each isolate ONE shape (a join, a carried loop
## value, a field projection, a defer) and say in their header what the graph
## must contain and which reads must be FINAL. `NN-shape.ssa` beside each is
## `tuck ssa` of it, checked by hand against that header before it was
## blessed.
##
## WHY GOLDENS, and not only assertions on single verdicts. A final read is
## licence to MOVE a value, and a missing one costs a copy; the ownership
## pass frees on that basis. A wrong graph is therefore a use-after-free or a
## leak in the emitted program, and it is rarely wrong in the one place a
## targeted assertion looks. The golden pins every value, every phi operand
## and every verdict, so any change to construction or to `finalUses` shows
## up as a diff somebody has to read.
##
## WHEN IT FAILS: read the diff against the file's header. If the new graph
## is right, `./tests/run ssa_golden --bless`. If you cannot say why it
## changed, it is the bug this exists to catch.
import std/[os, strutils, algorithm]
import ../harness

proc graphOnly(output: string): string =
  ## `tuck ssa` output from the first graph on: a size warning printed by
  ## the check is not part of what is pinned.
  var keep = false
  var lines: seq[string]
  for line in output.splitLines():
    if line.startsWith("fn "): keep = true
    if keep: lines.add line
  lines.join("\n").strip(leading = false) & "\n"

proc run*(t: var T) =
  var files: seq[string]
  for f in walkFiles("tests/ssa/*.tuck"): files.add f
  files.sort()
  var idx: seq[int]
  for f in files: idx.add t.needCmd(@["./tuck", "ssa", f])
  if t.phase != pReport: return
  if files.len == 0:
    t.no "the SSA goldens exist", "no tests/ssa/*.tuck found"
    return
  for k, f in files:
    let name = f.extractFilename.changeFileExt("")
    let (rc, outp) = t.resultOf(idx[k])
    if rc != 0:
      t.no name, "tuck ssa failed: " & outp.strip.splitLines()[^1]
      continue
    let got = graphOnly(outp)
    let want = f.changeFileExt("ssa")
    if t.bless:
      writeFile(want, got)
      t.ok name & " (blessed)"
    elif not fileExists(want):
      t.no name, "no golden yet — check the graph against the file's " &
                 "header, then --bless"
    elif readFile(want) == got:
      t.ok name
    else:
      t.no name, "graph changed:\n" & unifiedDiff(readFile(want), got, 10)
