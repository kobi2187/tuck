## Stackless transform, phase 1 (#216, docs/stackless-concurrency.md): the
## COLOURING — which fns become frames and where each can pause — pinned
## before any splitting is built on it.
##
## `tuck frames` prints the plan; each program here has its report pinned in
## a golden beside it (`--bless` rewrites them; read the diff). The programs
## in tests/frames/ each isolate one rule; the examples are the real
## concurrency corpus: tasks (14, 28), task select (29, 30), sockets and
## sends (42), actors (26, 27).
import std/[os, strutils, algorithm]
import ../harness

const Examples = ["14-task", "28-async-task", "29-task-timeout",
                  "30-async-read", "42-net-echo", "26-actor-run",
                  "27-actor-select"]

proc reportOnly(output: string): string =
  ## The plan from its first line on: warnings, PENDING and SIZE notes the
  ## check printed are not part of what is pinned.
  var keep = false
  var lines: seq[string]
  for line in output.splitLines():
    if line.startsWith("frame ") or line.startsWith("native ") or
       line.startsWith("no frames"): keep = true
    if keep: lines.add line
  lines.join("\n").strip(leading = false) & "\n"

proc cases(): seq[tuple[name, src, golden: string]] =
  var own: seq[string]
  for f in walkFiles("tests/frames/*.tuck"): own.add f
  own.sort()
  for f in own:
    result.add (f.extractFilename.changeFileExt(""), f, f.changeFileExt("frames"))
  for ex in Examples:
    result.add (ex, "examples" / ex & ".tuck", "tests/frames" / "ex-" & ex & ".frames")

proc check(t: var T, name, golden, got: string) =
  if t.bless:
    writeFile(golden, got)
    t.ok name & " (blessed)"
  elif not fileExists(golden):
    t.no name, "no golden yet — check the plan against the rules, then --bless"
  elif readFile(golden) == got:
    t.ok name
  else:
    t.no name, "frame plan changed:\n" & unifiedDiff(readFile(golden), got, 10)

proc run*(t: var T) =
  ## Registers the frame-plan goldens: one per program in tests/frames and
  ## per concurrency example.
  let cs = cases()
  var idx: seq[int]
  for c in cs: idx.add t.needCmd(@["./tuck", "frames", c.src])
  if t.phase != pReport: return
  for k, c in cs:
    let (rc, outp) = t.resultOf(idx[k])
    if rc != 0:
      t.no c.name, "tuck frames failed: " & outp.strip.splitLines()[^1]
      continue
    t.check("frames " & c.name, c.golden, reportOnly(outp))
