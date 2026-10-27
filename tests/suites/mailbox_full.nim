## What a send does when it finds the actor's mailbox full — R6, ruled
## 2026-09-28: the program picks, per actor, `[on_full: drop | wait | assert]`.
##
## Every send used to DROP, silently: `discard enqueue(...)` on all three
## backends, so a `waitUntil` whose predicate needed a dropped message spun
## forever (KNOWN-BUGS-EVENTS.md, the actor playground). The first ruling was
## "block if that adds no overhead"; the check measured free (benches/SCORES.md,
## "R6"), and the second ruling made the policy the program's choice, with
## `wait` when none is written.
##
## The programs are built so a regression FAILS rather than hangs: the actor
## prints once every message has arrived, and the actors are drained at exit,
## so under the old drop the line is simply missing. A mailbox of 2 fed 1000
## sends is sure to fill, whatever the scheduling.

import std/[os, strutils]
import ../harness

const everyMessage = """
import console

actor Sink [queue: 2]:
  total: int = 0
  on add({n: int}) [io]:
    total += n
    if total == 500500:
      {text: "all 1000 arrived"} console::printLine

fn main() -> int [io]:
  for i in 1 .. 1000:
    Sink send add {n: i}
  return 0
"""

proc assertModeRun(t: var T, name: string, buildIdx, runIdx: int,
                   wantExit: int, wanted: string) =
  ## A build-and-run under one `--actors:` mode, read for its exit code AND
  ## its output — the same assertion `hostRuns` makes, for a mode it cannot
  ## pass a flag to. SKIP in the cheap modes, as there.
  if t.phase == pCollect: return
  if t.skippedCmd(buildIdx) or t.skippedCmd(runIdx):
    t.skip name
    return
  let (brc, bout) = t.resultOf(buildIdx)
  if brc != 0:
    t.no name, "build failed: " & bout
    return
  let (rc, outp) = t.resultOf(runIdx)
  if rc != wantExit:
    t.no name, "exit " & $rc & " (want " & $wantExit & "): " & outp
  elif wanted notin outp:
    t.no name, "the output never says '" & wanted & "': " & outp
  else:
    t.ok name

proc buildAndRunUnder(t: var T, mode: string): tuple[b, r: int] =
  ## Register `tuck b` of the current snippet under `--actors:<mode>`, and a
  ## run of what it built.
  let dir = t.curDir / (mode & "_out")
  let b = t.needCmd(@["./tuck", "b", t.curDir / "t.tuck", "--actors:" & mode,
                      "-o:" & dir, "--root:" & t.root], vBuild)
  let r = t.needCmdAfter(@[dir / "t"], b, proc (d: string) = discard, dir, vRun)
  (b, r)

proc run*(t: var T) =
  ## Registers the `on_full` assertions: the default waits on every backend
  ## and in every actor mode, `assert` stops the program, `drop` is the old
  ## bare enqueue, a self-send cannot wait, and the checker refuses any other
  ## word (TK-AC06).

  # --- unwritten means `wait`: nothing is lost --------------------------------
  t.src everyMessage
  t.okCheck "an actor with no on_full checks"
  t.emits "...and its send waits for room, the default", r"sendWaiting\("
  t.emitsOdin "...on Odin too", r"rt\.sendWaiting\(&self\.mailbox"
  t.hostRuns "a full mailbox holds the sender: every message arrives, on " &
             "every backend", 0, "all 1000 arrived"

  # The same program in the other two actor modes, which reach room by other
  # routes: single mode has main run the actor's coroutine; batch mode flushes
  # what it staged first.
  let (sb, sr) = t.buildAndRunUnder("single")
  let (bb, br) = t.buildAndRunUnder("batch")
  t.assertModeRun("...under --actors:single", sb, sr, 0, "all 1000 arrived")
  t.assertModeRun("...and under --actors:batch", bb, br, 0, "all 1000 arrived")

  # --- written `wait` is the same thing ---------------------------------------
  t.src everyMessage.replace("[queue: 2]", "[queue: 2, on_full: wait]")
  t.emits "`on_full: wait` spelled out is the default", r"sendWaiting\("

  # --- `drop` is the bare enqueue every send once was -------------------------
  #
  # Only what it EMITS is asserted: whether a message is actually lost depends
  # on whether the actor thread kept up, which no timing assertion can pin.
  t.src everyMessage.replace("[queue: 2]", "[queue: 2, on_full: drop]")
  t.okCheck "`on_full: drop` checks"
  t.emits "...and its send is the bare enqueue", r"discard enqueue\("
  t.omits "...with no wait behind it", r"sendWaiting\("
  t.emitsOdin "...on Odin too", r"_ = rt\.enqueue\(&self\.mailbox"

  # --- `assert` stops the program, naming the actor --------------------------
  #
  # `hold` never returns, so once the actor has taken it nothing drains the
  # mailbox again: the sends after it fill the ring and one of them must
  # find it full. A hundred sends against a capacity of two leaves no
  # scheduling under which that does not happen.
  t.src """
actor Stuck [queue: 2, on_full: assert]:
  spins: int = 0
  on hold({n: int}):
    for true:
      spins += 1
  on add({n: int}):
    spins += n

fn main() -> int:
  Stuck send hold {n: 0}
  for i in 1 .. 100:
    Stuck send add {n: i}
  return 0
"""
  t.okCheck "`on_full: assert` checks"
  t.emits "...and its send asserts", r"sendAsserting\("
  t.hostRuns "a send finding the mailbox full stops the program, naming the " &
             "actor, on every backend", 1, r"TUCK ACTOR \[Stuck\]: mailbox full"

  # --- an actor cannot wait on its own mailbox --------------------------------
  #
  # The actor that would make room is the one waiting, so the wait would never
  # end. Stopped with a message rather than hung — reached only once the send
  # has already found the mailbox full, so it costs a send that fits nothing.
  t.src """
actor Echo [queue: 2]:
  n: int = 0
  on go({k: int}):
    for i in 1 .. 10:
      Echo send tick {k: i}
  on tick({k: int}):
    n += k

fn main() -> int:
  Echo send go {k: 0}
  return 0
"""
  t.hostRuns "a self-send into a full mailbox stops rather than waiting " &
             "forever, on every backend", 1, "sent to itself"
  let (eb, er) = t.buildAndRunUnder("single")
  t.assertModeRun("...and under --actors:single, where the actor is a " &
                  "coroutine", eb, er, 1, "sent to itself")

  # --- any other word is refused ----------------------------------------------
  t.src everyMessage.replace("[queue: 2]", "[queue: 2, on_full: block]")
  t.badCheck "on_full takes drop, wait or assert (TK-AC06)", "TK-AC06"
  t.badCheck "...and the message names the three", "drop, wait or assert"

  # --- an attribute an actor does not take ------------------------------------
  #
  # Read by nothing, so a misspelled `on_full` silently meant `wait`. Ruled
  # 2026-09-28 together with dropping example 15's `priority: high`, which was
  # read by nothing either: message priority, if it comes, is a handler's.
  t.src everyMessage.replace("[queue: 2]", "[queue: 2, on_ful: drop]")
  t.badCheck "a misspelled on_full is refused, not read as the default " &
             "(TK-AC07)", "TK-AC07"
  t.src everyMessage.replace("[queue: 2]", "[queue: 2, priority: high]")
  t.badCheck "...and so is `priority`, which no actor takes", "no attribute 'priority'"

  # --- message priority: `on reset() [urgent]:` -------------------------------
  #
  # An urgent message is taken ahead of every ordinary one already waiting
  # (spec §9.1). `hold` keeps the actor busy while main queues five bumps, the
  # reset and three more; the reset must run before ANY bump (exit 40), where
  # an ordinary reset runs after the first five (45). On every backend, in
  # every actor mode, and from another module.
  const urgentActor = """
actor Box [queue: 16]:
  n: int = 0
  seen: int = -1
  spin: int = 0

  on hold():
    # long enough that main queues everything below before this ends
    for i in 0 ..< 30_000_000:
      spin = spin + 1

  on bump():
    n += 1

  on reset() [urgent]:
    # how many bumps ran before the reset: 0 when it jumped the queue
    seen = n
"""
  const urgentMain = """
fn done() -> bool:
  return Box.n == 8

fn main() -> int:
  Box send hold {}
  for i in 0 ..< 5:
    Box send bump {}
  Box send reset {}
  for i in 0 ..< 3:
    Box send bump {}
  Box.waitUntil {pred: :done}
  return Box.seen + 40
"""
  t.src urgentActor & urgentMain
  t.okCheck "[urgent] on an actor's `on` handler checks"
  t.hostRuns "an urgent message jumps the queue, on every backend", 40
  for mode in ["single", "batch"]:
    let (ub, ur) = t.buildAndRunUnder(mode)
    t.assertModeRun("...and under --actors:" & mode, ub, ur, 40, "")
  t.src urgentActor.replace(" [urgent]", "") & urgentMain
  t.hostRuns "...where an ordinary one waits its turn", 45
  t.src "import box\n" & urgentMain
  t.addFile "box.tuck", urgentActor
  t.hostRuns "...and an actor imported from another module keeps it", 40
  t.src "fn f() -> int [urgent]:\n  return 1\n\nfn main() -> int:\n  return {} f\n"
  t.badCheck "[urgent] anywhere but an actor's `on` handler is refused (TK-AC13)",
             "TK-AC13"

  t.finish()
