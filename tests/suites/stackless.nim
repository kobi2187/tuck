## `--concurrency:stackless` (#216, docs/stackless-concurrency.md), phase 2:
## tasks on the Nim backend run as frames and stages instead of minicoro
## coroutines, with the SAME semantics. So the assertion here is a
## differential one: each program is built under both flags and must exit
## with the same code and print the same lines in the same order. Order is
## the strict part: it is the scheduler's interleaving, and a yield moved
## by one statement shows up as a reordered line.
##
## The programs (tests/stackless/): `order` interleaves four tasks with
## yields, frame calls, branches that pause, a `return` from a branch,
## ownership `defer`s in both scopes, an unbound spawn and two awaits;
## `values` hands results back through frame fns, reassigns a local from
## one, and returns fallible values both ways; `loops` pauses inside a
## counted loop (with `continue`, and a `break` from a native loop nested in
## it), a `for cond:`, a loop over a Seq whose element feeds a frame call,
## and the arms of a `match`. Example 28 is the corpus program.
##
## What is not built yet is REFUSED, never run wrong: a pause inside
## `on select` (phase 4) at compile time, and a frame waiting on I/O or a
## timer (phase 4) at run time, with exit 70 and a message.
import std/[os, strutils]
import ../harness

const Programs = ["tests/stackless/order.tuck", "tests/stackless/values.tuck",
                  "tests/stackless/loops.tuck", "examples/28-async-task.tuck"]

proc buildRun(t: var T, mode: string): int =
  ## Build the current snippet under `--concurrency:<mode>` into its own
  ## dir and run it; the run's work index.
  let dir = t.curDir / mode
  let build = t.needCmd(@["./tuck", "b", t.curDir / "t.tuck", "--concurrency:" & mode,
                          "-o:" & dir, "--root:" & t.root], vBuild)
  t.needCmdAfter(@[dir / "t"], build, proc (d: string) = discard, dir, vRun)

proc runOutput(output: string): string =
  ## A run's stdout, without the build chatter the harness may interleave.
  for line in output.splitLines():
    if line.startsWith("built ") or line.startsWith("wrote "): continue
    result.add line & "\n"

proc same(t: var T, name: string, a, b: int) =
  if t.phase != pReport: return
  if t.skippedCmd(a) or t.skippedCmd(b):
    t.skip name
    return
  let (rcA, outA) = t.resultOf(a)
  let (rcB, outB) = t.resultOf(b)
  if rcA == rcB and runOutput(outA) == runOutput(outB): t.ok name
  else:
    t.no name, "stackful exit " & $rcA & ", stackless exit " & $rcB & "\n" &
               unifiedDiff(runOutput(outA), runOutput(outB), 5)

proc refusedAtCompile(t: var T) =
  t.src readFile("tests/stackless/select_refused.tuck")
  let idx = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--concurrency:stackless",
                        "-o:" & t.curDir, "--root:" & t.root], vEmit)
  if t.phase != pReport: return
  if t.skippedCmd(idx):
    t.skip "a pause inside on select is refused"
    return
  let (rc, outp) = t.resultOf(idx)
  if rc != 0 and "a pause inside select is not supported" in outp:
    t.ok "a pause inside on select is refused, by name (phase 4)"
  else: t.no "a pause inside on select is refused", "exit " & $rc & ": " & outp

proc refusedAtRun(t: var T) =
  t.src readFile("tests/stackless/parks.tuck")
  let run = t.buildRun("stackless")
  if t.phase != pReport: return
  if t.skippedCmd(run):
    t.skip "a frame waiting on a timer stops"
    return
  let (rc, outp) = t.resultOf(run)
  if rc == 70 and "parking a frame arrives in #216 phase 4" in outp:
    t.ok "a frame waiting on a timer stops with a message, not a hang (phase 4)"
  else: t.no "a frame waiting on a timer stops", "exit " & $rc & ": " & outp

proc flags(t: var T) =
  t.src readFile("examples/28-async-task.tuck")
  let bogus = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--concurrency:bogus"])
  let odin = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--odin",
                         "--concurrency:stackless", "-o:" & t.curDir], vEmit)
  if t.phase != pReport: return
  let (rcB, outB) = t.resultOf(bogus)
  if rcB != 0 and "available: stackful, stackless" in outB: t.ok "an unknown mode is refused"
  else: t.no "an unknown mode is refused", outB
  if t.skippedCmd(odin):
    t.skip "stackless is Nim-only so far"
    return
  let (rcO, outO) = t.resultOf(odin)
  if rcO != 0 and "Nim-only" in outO: t.ok "stackless on Odin is refused until phase 3"
  else: t.no "stackless on Odin is refused", outO

proc run*(t: var T) =
  ## Registers the stackless assertions: each program the same under both
  ## flags, and the not-yet-built shapes refused.
  for p in Programs:
    t.src readFile(p)
    let a = t.buildRun("stackful")
    let b = t.buildRun("stackless")
    t.same("same output and exit under both flags: " & p.extractFilename, a, b)
  t.refusedAtCompile()
  t.refusedAtRun()
  t.flags()
