## `Actor.pingUs` / `Actor.alive` — the actor's liveness channel (issue #74).
##
## A probe is a word in the actor's slot, not a message: it passes whatever
## waits in the mailbox, runs no handler, and is answered by the drain loop at
## the next message boundary with the ACTOR'S clock. The client supplies the
## deadline (`withinMs`), so "alive" needs no code in the actor.
##
## Two kinds of assertion. The checker ones pin the surface: the members exist
## on every actor, have the declared types, and an author's own member of the
## same name wins. The runs ones BUILD AND RUN a program on every backend and
## demand the same exit code, since the claim is that all three answer alike.
## Margins are generous (a handler of ~1 s against a 100 ms deadline) because
## the point is the ordering, not the number.

import std/strutils
import ../harness

const pinged = """
import scheduler

actor Counter [queue: 16]:
  total: int = 0

  on add({n: int}):
    total += n

fn sumReady() -> bool:
  return Counter.total == 3

fn main() -> int:
  Counter send add {n: 1}
  Counter send add {n: 2}
  Counter.waitUntil {pred: :sumReady}
  if not Counter.alive {withinMs: 500}:
    return 1
  let p = Counter.pingUs {withinMs: 500}
  if not p.ok:
    return 2
  return 0
"""

const stuck = """
import scheduler

actor Slow [queue: 16]:
  done: int = 0

  on grind({n: int}):
    var x = 0
    for i in 1 .. n:
      x += i
    done = x

fn finished() -> bool:
  return Slow.done != 0

fn main() -> int:
  Slow send grind {n: 400000000}
  if Slow.alive {withinMs: 100}:
    return 1
  let late = Slow.pingUs {withinMs: 100}
  if late.ok:
    return 2
  Slow.waitUntil {pred: :finished}
  if not Slow.alive {withinMs: 500}:
    return 3
  return 0
"""

proc run*(t: var T) =
  ## Registers the checker assertions and the build-and-run ones.
  t.src pinged
  t.okCheck "alive and pingUs check on a plain actor"
  t.hostRuns "an idle or busy actor answers a ping: alive, and a delay", 0

  t.odinTracked "pinging leaks nothing on Odin", 0

  t.src stuck
  t.hostRuns "an actor inside a long handler is not alive; once it ends it is", 0

  t.src pinged.replace("Counter.alive {withinMs: 500}", "Counter.alive {withinMs: \"x\"}")
  t.badCheck "the deadline must be an int", "withinMs|expects int"

  t.src pinged.replace("let p = Counter.pingUs {withinMs: 500}\n  if not p.ok:",
                       "let p = Counter.pingUs {withinMs: 500}\n  if p:")
  t.badCheck "pingUs is an optional delay, not a bool", "bool|int"

  # An author's own member of the same name is theirs: the built-in steps aside.
  t.src """
actor Own:
  n: int = 0

  fn alive({withinMs: int}) -> bool:
    return n == 0

fn main() -> int:
  return 0
"""
  t.okCheck "an actor's own `alive` member is not shadowed"
