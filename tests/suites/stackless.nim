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
## Phase 5: under --actors:single an actor whose handlers wait only on
## mailboxes runs as a frame (examples 26 and 27, the two Savina ports,
## `sends`), the same as the coroutine actor it replaces.
##
## `hoists`: a frame call nested in a larger expression (an `if` and a loop
## condition, a match subject, a range end, an arithmetic expression) and a
## returned value that waits are hoisted into frame temps first.
##
## Phase 6 (#219): a callee's frame is built inside its caller's, an
## awaited task's inside its awaiter's or on main's stack; `recursion` keeps
## the heap on its call cycle only. `--frames:static` builds example 28 with
## no frame on the heap, and refuses `order` and `recursion`, naming why.
##
## What is not cut yet is REFUSED, never run wrong: here, a pause inside a
## `defer`, at compile time with its line and the way out
## (--concurrency:stackful).
import std/[os, strutils]
import ../harness

const Programs = ["tests/stackless/order.tuck", "tests/stackless/values.tuck",
                  "tests/stackless/loops.tuck", "tests/stackless/parks.tuck",
                  "tests/stackless/sends.tuck", "tests/stackless/hoists.tuck",
                  "tests/stackless/recursion.tuck",
                  "examples/28-async-task.tuck",
                  "examples/29-task-timeout.tuck", "examples/30-async-read.tuck"]
  # examples/42-net-echo (sockets) runs the same too, checked by hand: it
  # binds a fixed port, so it cannot run beside itself in the pool.

type Backend = enum bNim = "", bOdin = "--odin", bD = "--dlang"

proc binary(b: Backend): string =
  case b
  of bNim: "t"
  of bOdin: "t_odin"
  of bD: "t_d"

proc buildDir(t: T, mode: string, b: Backend, extra: seq[string]): string =
  t.curDir / (mode & $b & extra.join("").replace(":", "_").replace("-", ""))

proc build(t: var T, mode: string, b = bNim, extra: seq[string] = @[]): int =
  var argv = @["./tuck", "b", t.curDir / "t.tuck", "--concurrency:" & mode,
               "-o:" & t.buildDir(mode, b, extra), "--root:" & t.root] & extra
  if b != bNim: argv.add $b
  t.needCmd(argv, vBuild)

proc buildRun(t: var T, mode: string, b = bNim, extra: seq[string] = @[]): int =
  ## Build the current snippet under `--concurrency:<mode>` (and `extra`
  ## flags) for backend `b` into its own dir and run it; the run's index.
  let dir = t.buildDir(mode, b, extra)
  t.needCmdAfter(@[dir / b.binary], t.build(mode, b, extra),
                 proc (d: string) = discard, dir, vRun)

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
  t.src readFile("tests/stackless/defer_refused.tuck")
  let idx = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--concurrency:stackless",
                        "-o:" & t.curDir, "--root:" & t.root], vEmit)
  if t.phase != pReport: return
  if t.skippedCmd(idx):
    t.skip "a pause inside defer is refused"
    return
  let (rc, outp) = t.resultOf(idx)
  if rc != 0 and "a pause inside a `defer` is not cut" in outp and "--concurrency:stackful" in outp:
    t.ok "a pause inside defer is refused, by name, pointing at --concurrency:stackful"
  else: t.no "a pause inside defer is refused", "exit " & $rc & ": " & outp

proc flags(t: var T) =
  t.src readFile("examples/28-async-task.tuck")
  let bogus = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--concurrency:bogus"])
  if t.phase != pReport: return
  let (rcB, outB) = t.resultOf(bogus)
  if rcB != 0 and "available: stackful, stackless" in outB: t.ok "an unknown mode is refused"
  else: t.no "an unknown mode is refused", outB

const ActorPrograms = ["examples/26-actor-run.tuck", "examples/27-actor-select.tuck",
                       "benches/savina/pingpong.tuck", "benches/savina/threadring.tuck",
                       "tests/stackless/sends.tuck", "tests/stackless/mixed_actors.tuck"]
  ## Under --actors:single, an actor whose handlers wait only on mailboxes
  ## runs as a FRAME under stackless (phase 5): no coroutine, no stack.

const BatchPrograms = ActorPrograms[0 .. ^2]
  ## mixed_actors waits on a predicate over a SECOND actor's state, which is
  ## re-tested only when the first one handles a message: under batch the
  ## second's messages cross after that last test, and the wait never ends
  ## — on Nim as on the others, so it is the program's race, not a backend's.

proc label(b: Backend): string =
  case b
  of bNim: "Nim"
  of bOdin: "Odin"
  of bD: "D"

proc actorModes(t: var T, others: seq[Backend]) =
  ## Odin and D reach parity with Nim's actor modes: each actor program,
  ## under --actors:single and --actors:batch, in both concurrency modes,
  ## exits and prints what Nim stackful does under the same mode.
  for mode in ["single", "batch"]:
    # batch at 4 against the programs' 2-deep mailboxes: runs both fill and flush
    let flags = if mode == "batch": @["--actors:batch", "--batch-count:4"]
                else: @["--actors:single"]
    for p in (if mode == "batch": @BatchPrograms else: @ActorPrograms):
      t.src readFile(p)
      let reference = t.buildRun("stackful", bNim, flags)
      if mode == "batch":
        t.same("--actors:batch: Nim stackless matches stackful: " & p.extractFilename,
               reference, t.buildRun("stackless", bNim, flags))
      for b in others:
        for cm in ["stackful", "stackless"]:
          t.same("--actors:" & mode & ": " & b.label & " " & cm &
                 " matches Nim: " & p.extractFilename,
                 reference, t.buildRun(cm, b, flags))

proc actorFrames(t: var T) =
  ## Each actor program the same under --actors:single in both modes, and
  ## the stackless build really starting a frame actor (not the old path).
  for p in ActorPrograms:
    t.src readFile(p)
    let single = @["--actors:single"]
    let reference = t.buildRun("stackful", bNim, single)
    t.same("--actors:single: stackless matches stackful: " & p.extractFilename,
           reference, t.buildRun("stackless", bNim, single))
    let dir = t.buildDir("stackless", bNim, single)
    let framed = t.needCmdAfter(@["grep", "-q", "tuckStartActorFrame", dir / "t.nim"],
                                t.build("stackless", bNim, single),
                                proc (d: string) = discard, dir, vBuild)
    if t.phase == pReport:
      let name = "--actors:single: a frame actor is started: " & p.extractFilename
      if t.skippedCmd(framed): t.skip name
      elif t.resultOf(framed)[0] == 0: t.ok name
      else: t.no name, "no tuckStartActorFrame in the emitted Nim"

proc checkRun(t: var T, name: string, idx, rc: int, says = "") =
  ## Command `idx` exited `rc` (and printed `says`, when given).
  if t.phase != pReport: return
  if t.skippedCmd(idx): t.skip name; return
  let (got, outp) = t.resultOf(idx)
  if got == rc and (says == "" or says in outp): t.ok name
  else: t.no name, "exit " & $got & " (want " & $rc & "): " & outp

proc staticFrames(t: var T, others: seq[Backend]) =
  ## --frames:static (#219): a program whose every frame embeds builds and
  ## runs; one with a spawned task, a cycle or a wait is refused, each
  ## reason named; the flag's bad uses are refused.
  t.src readFile("examples/28-async-task.tuck")
  for b in @[bNim] & others:
    t.checkRun("--frames:static builds and runs a program whose every frame embeds " & $b,
               t.buildRun("stackless", b, @["--frames:static"]), 42)
  t.src readFile("tests/stackless/order.tuck")
  let refused = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--frames:static",
                            "--concurrency:stackless",
                            "-o:" & t.curDir, "--root:" & t.root], vEmit)
  t.checkRun("--frames:static refuses a wait on a helper stack, by place", refused, 1,
             "'console::printLine' waits inside the runtime, on a helper stack")
  t.checkRun("...and a spawned task, by place", refused, 1,
             "task 'worker' is spawned, not awaited: its frame comes from the heap")
  t.src readFile("tests/stackless/recursion.tuck")
  let cyc = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck", "--frames:static",
                        "--concurrency:stackless",
                        "-o:" & t.curDir, "--root:" & t.root], vEmit)
  t.checkRun("...and a call cycle, by name", cyc, 1, "sumDown is on a call cycle")
  let bogus = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--frames:bogus"])
  t.checkRun("an unknown frame policy is refused", bogus, 1, "available: heap (default), static")
  let both = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--frames:static",
                         "--concurrency:stackful"])
  t.checkRun("--frames:static under stackful is refused", both, 1, "this build is --concurrency:stackful")

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
      t.same(b.label & " stackless matches the Nim reference: " & name,
             reference, t.buildRun("stackless", b))
  t.actorFrames()
  t.actorModes(others)
  t.staticFrames(others)
  t.refusedAtCompile()
  t.flags()
