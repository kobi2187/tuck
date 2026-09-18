## Bench 2 — actor message throughput.
## One actor, N messages flooded into its mailbox, drained on the ACTOR'S OWN
## THREAD (the model since 2026-09-18; it was a coroutine on main's thread).
## Mirrors exactly what codegen emits for an actor: a mailbox seq, a drain
## proc that empties it, tuckStartActor to run the loop, tuckNotifySend after
## each enqueue, and waitUntil on public state. Measures messages/sec end to
## end (enqueue + schedule + drain + handler).
##
## Run via benches/run.sh (builds with the arsenal path + coroutine flags).

import std/[times, os, strutils, locks]
import ../compiler/tuck_async

# --- the "actor": public state + mailbox + drain (as codegen would emit) ---
#
# The mailbox is LOCK-GUARDED, matching what codegen emits (tuck_rt's
# Mailbox[T, Cap] has carried a Lock from the start). Under the previous
# cooperative model a bare seq was safe because only one thing ran at a time;
# with the actor on its own thread, flooding it from main while it drains is a
# genuine race, so a bench using a bare seq would be measuring a program that
# is not the one codegen produces.
var mbLock: Lock
var mailbox: seq[int]
var sum: int64
var handled: int

proc drain(): bool {.gcsafe.} = ({.cast(gcsafe).}:
  var batch: seq[int]
  acquire(mbLock)
  swap(batch, mailbox)     # take the whole batch, release fast
  release(mbLock)
  if batch.len == 0: return false
  for m in batch:          # handler: accumulate
    sum += m
    inc handled
  result = true)

proc main() =
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 1_000_000

  tuckAsyncInit()
  initLock(mbLock)
  let slot = tuckStartActor(drain)

  let t0 = epochTime()
  for i in 1 .. n:
    acquire(mbLock)
    mailbox.add(i)          # `Actor send handler {payload}`
    release(mbLock)
    tuckNotifySend()
  # `Actor.waitUntil {pred: ...}` — registered with the actor, evaluated on its
  # thread, no polling. The predicate reads `handled`, which only that thread
  # writes, so it is read where it lives.
  tuckWaitOn(slot, proc(): bool = handled >= n)
  let t = epochTime() - t0

  doAssert handled == n, "handled " & $handled & "/" & $n
  let want = n.int64 * (n.int64 + 1) div 2
  doAssert sum == want, "sum " & $sum & " want " & $want

  echo "actor throughput: N=", n
  echo "  ", n, " msgs in ", (t*1000).formatFloat(ffDecimal,1), " ms  = ",
       (n.float/t/1e6).formatFloat(ffDecimal,2), " M msgs/sec"

main()
