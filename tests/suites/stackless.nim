## `--concurrency:stackless` (#216, docs/stackless-concurrency.md), phases
## 2-3: tasks on all three backends run as frames and stages instead of
## minicoro coroutines, with the SAME semantics. So the assertion here is a
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
## Phase 4 adds the statements that wait INSIDE the runtime — `parks` (a
## timer), `sends` (sends into a mailbox that fills, and an actor's
## `waitUntil`), examples 29 and 30 (`on select` racing a read and a
## timeout): each runs on a helper stack and matches the reference.
##
## What is not built yet is REFUSED, never run wrong: here, a frame call in
## an `if` condition, at compile time with its line.
import std/[os, strutils]
import ../harness

const Programs = ["tests/stackless/order.tuck", "tests/stackless/values.tuck",
                  "tests/stackless/loops.tuck", "tests/stackless/parks.tuck",
                  "tests/stackless/sends.tuck", "examples/28-async-task.tuck",
                  "examples/29-task-timeout.tuck", "examples/30-async-read.tuck"]
  # examples/42-net-echo (sockets) runs the same too, checked by hand: it
  # binds a fixed port, so it cannot run beside itself in the pool.

type Backend = enum bNim = "", bOdin = "--odin", bD = "--dlang"

proc binary(b: Backend): string =
  case b
  of bNim: "t"
  of bOdin: "t_odin"
  of bD: "t_d"

proc buildRun(t: var T, mode: string, b = bNim): int =
  ## Build the current snippet under `--concurrency:<mode>` for backend `b`
  ## into its own dir and run it; the run's work index.
  let dir = t.curDir / (mode & $b)
  var argv = @["./tuck", "b", t.curDir / "t.tuck", "--concurrency:" & mode,
               "-o:" & dir, "--root:" & t.root]
  if b != bNim: argv.add $b
  let build = t.needCmd(argv, vBuild)
  t.needCmdAfter(@[dir / b.binary], build, proc (d: string) = discard, dir, vRun)

proc toolchains(t: var T): seq[Backend] =
  ## The other backends this machine can build: Odin is required when
  ## TUCK_REQUIRE_ODIN=1 (as in CI), and skipped with a notice otherwise.
  if findOdin() != "": result.add bOdin
  elif getEnv("TUCK_REQUIRE_ODIN") == "1" and t.phase == pReport:
    t.no "odin is available", "odin not found and TUCK_REQUIRE_ODIN=1"
  if findDmd() != "": result.add bD

proc runOutput(output: string): string =
  ## A run's stdout, without the build chatter the harness may interleave.
  for line in output.splitLines():
    if line.startsWith("built ") or line.startsWith("wrote "): continue
    result.add line & "\n"

proc same(t: var T, name: string, a, b: int) =
  ## Run `b` exits and prints exactly what reference run `a` does.
  if t.phase != pReport: return
  if t.skippedCmd(a) or t.skippedCmd(b):
    t.skip name
    return
  let (rcA, outA) = t.resultOf(a)
  let (rcB, outB) = t.resultOf(b)
  if rcA == rcB and runOutput(outA) == runOutput(outB): t.ok name
  else:
    t.no name, "reference exit " & $rcA & ", this exit " & $rcB & "\n" &
               unifiedDiff(runOutput(outA), runOutput(outB), 5)

proc refusedAtCompile(t: var T) =
  t.src readFile("tests/stackless/cond_refused.tuck")
  let idx = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--concurrency:stackless",
                        "-o:" & t.curDir, "--root:" & t.root], vEmit)
  if t.phase != pReport: return
  if t.skippedCmd(idx):
    t.skip "a frame call in an if condition is refused"
    return
  let (rc, outp) = t.resultOf(idx)
  if rc != 0 and "a frame call in an `if` condition is not supported" in outp:
    t.ok "a frame call in an if condition is refused, by name"
  else: t.no "a frame call in an if condition is refused", "exit " & $rc & ": " & outp

proc flags(t: var T) =
  t.src readFile("examples/28-async-task.tuck")
  let bogus = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--concurrency:bogus"])
  if t.phase != pReport: return
  let (rcB, outB) = t.resultOf(bogus)
  if rcB != 0 and "available: stackful, stackless" in outB: t.ok "an unknown mode is refused"
  else: t.no "an unknown mode is refused", outB

proc run*(t: var T) =
  ## Registers the stackless assertions: each program the same under both
  ## flags, on every backend, and the not-yet-built shapes refused.
  ##
  ## The REFERENCE is Nim stackful: it yields before every [io] call in a
  ## task body, as spec §9.2 says. Odin and D stackful do not (their task
  ## bodies run straight through), so their interleaving differs; their
  ## stackless builds go through the shared splitter and match the
  ## reference, which is what is asserted for them.
  let others = t.toolchains()
  for p in Programs:
    t.src readFile(p)
    let name = p.extractFilename
    let reference = t.buildRun("stackful")
    t.same("Nim: same output and exit under both flags: " & name,
           reference, t.buildRun("stackless"))
    for b in others:
      let label = (if b == bOdin: "Odin" else: "D")
      t.same(label & " stackless matches the Nim reference: " & name,
             reference, t.buildRun("stackless", b))
  t.refusedAtCompile()
  t.flags()
