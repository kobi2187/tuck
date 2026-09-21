## `result` is GONE, and a handler may not declare a return type.
##
## History, because the shape of the fix is the point. `result` was bound
## inside a handler to the handler's declared return type. Nothing bound it
## before that, so it synthesized as Unknown and every assignment was
## accepted; binding it made the type real. But two problems survived:
##
##   1. Nothing ever checked that `result` was ASSIGNED. A path that skipped
##      it yielded whatever the backend zero-inits — exactly what TK-TY16
##      refuses for a record field nobody set. A zero is not a value.
##   2. Nothing COLLECTED it. `handleMsg` returns nothing, so `result = x`
##      emitted a local the emitter then discarded. The declared return type
##      promised a reply the runtime cannot deliver: an actor message is
##      fire-and-forget (spec 9.1) and correlation tokens are designed, not
##      implemented (TODO.md section 1).
##
## Ruling 2026-09-06: reject the return type (TK-AC02), which removes the only
## thing `result` was bound to, and `result` with it. It is now an ordinary
## undeclared name. The reply gap stays visible rather than looking supported.

import ../harness

proc run*(t: var T) =
  # A handler declaring a return type is the construct that cannot be honoured.
  t.src """
actor Counter:
  count: int = 0

  on get() -> {count: int}:
    count = count

fn main() -> int:
  return 0
"""
  t.badCheck "a handler may not declare a return type", "TK-AC02"
  t.badCheck "...and the message says why: no reply channel",
             "cannot reply yet"

  # With nothing to bind it to, `result` is just a name nobody declared.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    result = n

fn main() -> int:
  return 0
"""
  t.badCheck "`result` in a handler is an undeclared name", "result"

  # A handler with no return type is the normal shape and still works.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    count += n

fn main() -> int:
  return 0
"""
  t.okCheck "a handler with no return type is fine"

  # `-> void` is NOT a reply claim: it carries nothing and means exactly what
  # omitting the type means. Only a type that would carry a VALUE back
  # promises something there is no channel for. The first version of this
  # rule rejected `-> void` too and broke three existing actors.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}) -> void:
    count += n

fn main() -> int:
  return 0
"""
  t.okCheck "an explicit `-> void` handler is still fine"

  # The actor's own fields still resolve inside a handler — a regression guard,
  # since removing the `result` binding must not disturb the field scope.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    count += n
    self.count += 0

fn main() -> int:
  return 0
"""
  t.okCheck "actor fields still resolve, bare and through self"

  # Assigning to a name nothing declares. Not actor-specific — it is the same
  # rule in a plain fn, which is where the fix landed.
  t.src """
actor Counter:
  count: int = 0

  on bump({n: int}):
    nosuchfield += n

fn main() -> int:
  return 0
"""
  t.quietly: t.badCheck("an unknown actor field is caught", "nosuchfield")
  t.bugFixed "an undeclared assignment target is caught in a handler"

  t.src """
fn f({n: int}) -> void:
  nosuchvar += n

fn main() -> int:
  return 0
"""
  t.quietly:
    t.badCheck("an undeclared assignment target is caught in a plain fn too",
               "nosuchvar")
  t.bugFixed "...and the same in a plain fn, which is where the fix landed"

  # --- an idle actor must not keep the program alive (#28) -----------------
  #
  # An actor is a DAEMON: main owns the lifecycle, so a program whose main
  # returns must exit even though the actor's drain loop never ends. Odin
  # broke that — its emitted drain ended in `rt.coroYield()`, which re-queues
  # the coroutine before suspending, so an idle actor stayed permanently
  # runnable and `tuckRun` never reached "nothing ready and nothing waiting".
  # The binary hung; Nim and D exited 0, because in those two the RUNTIME owns
  # the actor loop and decides whether to park.
  #
  # A task is declared but never spawned, which is what puts `tuckRun()` in
  # the entry point at all — without it the loop is never driven and the hang
  # cannot show. That is examples/20's exact shape.
  t.src """
actor Idle [queue: 4]:
  n: int = 0

  on bump():
    n += 1

task never() -> !void [io]:
  return

fn main() -> int:
  return 3
"""
  t.runs "an idle actor does not keep a finished main alive", 3
  t.hostRuns "...on every backend", 3

  # ...and parking must not cost delivery: tuckNotifySend readies a parked
  # actor exactly as the reactor readies an I/O park. Asserted by VALUE — 6 is
  # the sum, so a dropped send or an actor that never ran answers with
  # something else rather than merely a different exit status.
  t.src """
import scheduler

actor Tally [queue: 8]:
  n: int = 0

  on add({by: int}):
    n += by

fn done() -> bool:
  return Tally.n >= 6

fn main() -> int [io]:
  Tally send add {by: 1}
  Tally send add {by: 2}
  Tally send add {by: 3}
  Tally.waitUntil {pred: :done}
  return Tally.n
"""
  t.runs "a parked actor still wakes on send and drains every message", 6
  t.hostRuns "...on every backend", 6

  # --- Actor.waitUntil: the predicate runs on the ACTOR's thread ------------
  #
  # Two tiers of observation (spec 9.1). A field read is a SNAPSHOT — cheap,
  # safe, and not ordered against your own sends. `Actor.waitUntil` observes
  # the TRANSITION: the predicate is registered with that actor and evaluated
  # on its thread after each message, where the state is settled and unshared.
  #
  # Registered the way `Pool.acquire` is registered — a signature named
  # `<Actor>.waitUntil` in the flat table (typecheck_collect) — so the call
  # resolves through the ordinary path and the compiler special-cases no
  # library name. The actor is named by the AUTHOR, not inferred.
  #
  # Asserted by VALUE and by TIME: three handlers that each sleep 40ms mean a
  # correct wait returns 6 after ~120ms. A test that only checked the value
  # would also pass on a lucky race.
  t.src """
import time

actor Tally [queue: 8]:
  n: int = 0

  on add({by: int}):
    {ms: 40} sleepMs
    n += by

fn done() -> bool:
  return Tally.n >= 6

fn main() -> int [io]:
  Tally send add {by: 1}
  Tally send add {by: 2}
  Tally send add {by: 3}
  Tally.waitUntil {pred: :done}
  return Tally.n
"""
  t.okCheck "`Actor.waitUntil` resolves as a static member call"
  t.emits "...and lowers to the runtime's registration, not a poll",
          "tuckWaitOn"
  t.runs "...and blocks until every message has been handled", 6
  t.hostRuns "...on every backend", 6

  # A predicate over TWO actors has no home: no single actor can evaluate it
  # soundly, which is the racy case wearing a safe-looking spelling. The two
  # waits compose instead, and each is evaluated where its state lives.
  t.src """
actor A [queue: 4]:
  n: int = 0

  on put({v: int}):
    n = v

actor B [queue: 4]:
  n: int = 0

  on put({v: int}):
    n = v

fn aReady() -> bool:
  return A.n > 0

fn bReady() -> bool:
  return B.n > 0

fn main() -> int [io]:
  A send put {v: 2}
  B send put {v: 5}
  A.waitUntil {pred: :aReady}
  B.waitUntil {pred: :bReady}
  return A.n + B.n
"""
  t.okCheck "two actors are waited on separately, not by one predicate"
  t.runs "...and both are observed", 7
  t.hostRuns "...on every backend", 7

  # A `match` whose arms are SENDS. This is not a contrived shape: an actor
  # is a compile-time singleton with no reference type, so a router over N
  # shards has nothing to index and cannot be a loop — `match` with one arm
  # per actor is the only spelling, and `benches/apps/world_server.tuck` is
  # written on it.
  #
  # A send is two lines on Nim (enqueue, then a notify that NAMES the actor),
  # and the arm emitter only bumped the indent for a body that was a block.
  # The notify fell out of the arm and nim answered "expression expected, but
  # found 'keyword of'". Every tracked `match` arm was a block or a one-line
  # `return`, so nothing had caught it. KNOWN-BUGS-EVENTS.md EV-16.
  #
  # Asserted by VALUE: 1 + 2 + 20 reaches all three arms, so an arm that does
  # not compile, does not run, or runs twice answers with a different number
  # rather than merely a different exit status. The three weights are chosen
  # so no wrong combination sums to 23 — and so the total FITS IN 8 BITS,
  # which 1 + 20 + 300 did not: it came back as 127.
  t.src """
actor Tally [queue: 16]:
  n: int = 0
  seen: int = 0

  on add({v: int}):
    n += v
    seen += 1

fn route({s: int}):
  match s:
    | 0 -> Tally send add {v: 1}
    | 1 -> Tally send add {v: 2}
    | _ -> Tally send add {v: 20}

fn counted() -> bool:
  return Tally.seen == 3

fn main() -> int:
  {s: 0} route
  {s: 1} route
  {s: 9} route
  Tally.waitUntil {pred: :counted}
  return Tally.n
"""
  t.okCheck "a match arm may be a bare send"
  t.emits "...and its notify stays inside the arm",
          r"of 0:\n {4}discard enqueue\([^\n]*\n {4}tuckNotifySend"
  t.runs "...and every arm delivers", 23
  t.hostRuns "...on every backend", 23

  t.finish()
