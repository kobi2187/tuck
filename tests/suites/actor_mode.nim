## `--actors:MODE` and its batch knobs — the CLI surface of
## compiler/actor_mode.nim.
##
## Every assertion here is about what the COMPILER does with the flag, not
## about how an actor then behaves: `thread` is the only mode the runtime has,
## so there is no second behaviour to compare against yet. What is worth
## gating now is that a mode nobody implemented cannot be built silently, and
## that a knob which would do nothing is refused rather than ignored.
##
## Needs needCmd/resultOf rather than okCheck: those hardcode their `./tuck`
## argv with no way to pass a flag through (same reason as when_target).

import std/[os, strutils]
import ../harness

const src = """
actor Counter:
  total: int
  on add(n: int):
    self.total = self.total + n

fn main() -> int:
  Counter send add {n: 1}
  return 0
"""

proc checkWith(t: var T, flags: seq[string]): int =
  ## Register `tuck ch` with extra flags; returns the work index.
  t.src src
  t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--root:" & t.root] & flags)

proc assertRejects(t: var T, name: string, idx: int, wanted: string) =
  ## The flag must be refused with a non-zero exit AND say why. Exit code
  ## alone is not enough: a build script stops either way, but a person has
  ## to know which flag to fix.
  if t.phase == pCollect: return
  let (rc, outp) = t.resultOf(idx)
  if rc == 0:
    t.no name, "accepted, exit 0 — expected a refusal. Output: " & outp
  elif wanted notin outp:
    t.no name, "refused, but the message never says '" & wanted & "': " & outp
  else:
    t.ok name

proc assertAccepts(t: var T, name: string, idx: int) =
  if t.phase == pCollect: return
  let (rc, outp) = t.resultOf(idx)
  if rc == 0: t.ok name
  else: t.no name, "rejected (exit " & $rc & "): " & outp

proc run*(t: var T) =
  # --- the default and the one implemented mode -----------------------------

  let bare = t.checkWith(@[])
  let thread = t.checkWith(@["--actors:thread"])

  # --- a mode with no runtime behind it is refused, not quietly downgraded --

  let single = t.checkWith(@["--actors:single"])
  let batch = t.checkWith(@["--actors:batch", "--batch-count:8"])

  # --- single mode is not just accepted, it RUNS -----------------------------
  #
  # The program is 26-actor-run's shape: sends, then a waitUntil over the
  # actor's public state, returning the sum as the exit code. Under single
  # mode the actor is a coroutine on main's own thread, so `waitUntil` has to
  # drive the scheduler rather than block on it — get that wrong and this
  # hangs rather than failing, which is why it is an assertion and not a
  # hand-check.
  t.src """
import scheduler

actor Counter [queue: 128]:
  total: int = 0

  on add({n: int}):
    total += n

fn sumReady() -> bool:
  return Counter.total == 55

fn main() -> int:
  for i in 1 .. 10:
    Counter send add {n: i}
  Counter.waitUntil {pred: :sumReady}
  return Counter.total
"""
  let singleDir = t.curDir / "single_out"
  let singleBuild = t.needCmd(@["./tuck", "b", t.curDir / "t.tuck",
                                "--actors:single", "-o:" & singleDir,
                                "--root:" & t.root], vBuild)
  let singleRun = t.needCmdAfter(@[singleDir / "t"], singleBuild,
                                 proc (dir: string) = discard, singleDir, vRun)

  # --- a name that is not a mode ---------------------------------------------

  let bogus = t.checkWith(@["--actors:bogus"])

  # --- knobs that would do nothing ------------------------------------------

  let strayCount = t.checkWith(@["--batch-count:32"])
  let strayTimeout = t.checkWith(@["--actors:thread", "--batch-timeout:5"])

  # --- a batch that would never flush ---------------------------------------

  let noFlush = t.checkWith(@["--actors:batch", "--batch-count:0",
                              "--batch-timeout:0"])

  # --- knob values that are not numbers -------------------------------------

  let notNumber = t.checkWith(@["--actors:batch", "--batch-count:abc"])
  let negative = t.checkWith(@["--actors:batch", "--batch-timeout:-5"])

  t.assertAccepts("no --actors: builds, thread being the default", bare)
  t.assertAccepts("--actors:thread is accepted", thread)

  t.assertAccepts("--actors:single is accepted", single)
  t.assertRejects("--actors:batch is refused while the runtime lacks it",
                  batch, "not implemented yet")

  if t.phase != pCollect:
    if t.skippedCmd(singleBuild) or t.skippedCmd(singleRun):
      t.skip "an actor program runs under --actors:single"
    else:
      let (brc, bout) = t.resultOf(singleBuild)
      if brc != 0:
        t.no "an actor program runs under --actors:single",
             "build failed: " & bout
      else:
        let (rc, outp) = t.resultOf(singleRun)
        if rc == 55:
          t.ok "an actor program runs under --actors:single"
        else:
          t.no "an actor program runs under --actors:single",
               "exit " & $rc & " (want 55, the sum the actor accumulated): " & outp
  t.assertRejects("an unknown mode names the ones that exist",
                  bogus, "thread, single, batch")

  t.assertRejects("--batch-count without --actors:batch is refused",
                  strayCount, "only mean something under --actors:batch")
  t.assertRejects("--batch-timeout without --actors:batch is refused",
                  strayTimeout, "only mean something under --actors:batch")

  t.assertRejects("a batch with both thresholds at 0 never flushes, so it is refused",
                  noFlush, "never flushes")

  t.assertRejects("a non-numeric --batch-count is refused, not read as 0",
                  notNumber, "needs a number")
  t.assertRejects("a negative --batch-timeout is refused",
                  negative, "cannot be negative")

  t.finish()
