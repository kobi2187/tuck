## Bench 2 — actor message throughput.
## One actor, N messages flooded into its mailbox, drained on the ACTOR'S OWN
## THREAD (the model since 2026-09-18; it was a coroutine on main's thread).
## Uses compiler/tuck_rt.Mailbox's own enqueue/dequeue — the exact runtime
## type codegen instantiates as `mailbox*: Mailbox[MsgType, queueSize]` and
## the exact lock its enqueue/dequeue acquire — rather than a hand-rolled
## seq+Lock approximation, so a lock change in tuck_rt.nim shows up here.
## Cap is sized past N so the ring never fills: this bench isolates drain
## throughput, not the `[queue: N]` backpressure/drop policy (spec §9.1),
## which is a separate concern from how fast a full mailbox drains.
##
## Run via benches/run.sh (builds with the arsenal path + coroutine flags).

import std/[times, os, strutils]
import ../compiler/tuck_async
import ../compiler/tuck_rt

# --- the "actor": public state + mailbox + drain (as codegen would emit) ---
const Cap = 2_000_000
var mailbox: Mailbox[int, Cap]
var sum: int64
var handled: int

proc drain(): bool {.gcsafe.} = ({.cast(gcsafe).}:
  var m: int
  result = false
  while dequeue(mailbox, m):   # `while dequeue(...)`, exactly as genActorDrain emits
    sum += m
    inc handled
    result = true)

proc main() =
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 1_000_000

  tuckAsyncInit()
  let slot = tuckStartActor(drain)

  let t0 = epochTime()
  for i in 1 .. n:
    doAssert enqueue(mailbox, i)   # `Actor send handler {payload}`; Cap rules out a drop
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
