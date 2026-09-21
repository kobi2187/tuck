## Bench 2 — actor message throughput.
## One actor, N messages flooded into its mailbox, drained on the ACTOR'S OWN
## THREAD (the model since 2026-09-18; it was a coroutine on main's thread).
## Uses compiler/tuck_rt.Mailbox itself — the exact runtime type codegen
## instantiates as `mailbox*: Mailbox[MsgType, queueSize]`, drained with the
## exact loop genActorDrain emits — rather than a hand-rolled approximation,
## so a mailbox change in tuck_rt.nim shows up here.
##
## TWO REGIMES, because they answer differently and only one of them is the
## interesting one:
##
##   1 sender   the actor is never the bottleneck, so mailbox changes wash out
##              in the noise. Kept because it is the simplest shape and a
##              collapse here would still be a real regression.
##   S senders  the contended case, and the one that ranks designs: every
##              sender wants the same lock, so what the DRAIN does with that
##              lock decides throughput.
##
## `benches/.bat N [senders]`, senders default 1. Cap is sized past N so the
## mailbox never fills: this isolates drain throughput, not the `[queue: N]`
## drop policy (spec §9.1), which is a separate question.
##
## Run via benches/run.sh (builds with the arsenal path + coroutine flags).

import std/[times, os, strutils]
import ../compiler/tuck_async
import ../compiler/tuck_rt

# --- the "actor": public state + mailbox + drain (as codegen would emit) ---
#
# THE MESSAGE IS AN ENVELOPE, not an int. codegen emits a struct — a tag plus
# the union of every handler's parameters — so 32 bytes is the realistic
# small case and an `int` mailbox is not one. This is load-bearing, not
# decoration: measured on `int`, the ring and the swap mailbox rank EQUAL,
# because at 8 bytes there is no copy worth avoiding. At 32 they do not.
type Msg = object
  tag: int
  body: array[3, int]

const Cap = 131072
  ## Big enough that a sender rarely finds it full, small enough that both
  ## buffers stay a sane size (the mailbox holds 2 * Cap — see tuck_rt).
  ## Sized past N instead would measure DRAM, not the mailbox protocol.
var mailbox: Mailbox[Msg, Cap]
var sum: int64
var handled: int

proc drain(): bool {.gcsafe.} = ({.cast(gcsafe).}:
  result = false
  for m in messages(mailbox):  # exactly the loop genActorDrain emits
    sum += m.tag
    inc handled
    result = true)

var senders: array[16, Thread[int]]
var perSender: int
var actorSlot: pointer   # what codegen keeps as `<Actor>Slot`

proc senderMain(id: int) {.thread.} = ({.cast(gcsafe).}:
  let m = Msg(tag: 1)
  for i in 1 .. perSender:
    # A real `send` DROPS on a full mailbox (spec §9.1). Retrying instead
    # keeps every message accounted for, so the number below is throughput
    # rather than throughput-times-an-unknown-delivery-rate.
    while not enqueue(mailbox, m): cpuRelax()
    tuckNotifySend(actorSlot))   # the send NAMES its actor, as codegen emits

proc main() =
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 1_000_000
  let nSenders = if paramCount() >= 2: parseInt(paramStr(2)) else: 1
  doAssert nSenders >= 1 and nSenders <= senders.len
  perSender = n div nSenders
  let total = perSender * nSenders

  tuckAsyncInit()
  let slot = tuckStartActor(drain)
  actorSlot = slot

  let t0 = epochTime()
  for s in 0 ..< nSenders:
    createThread(senders[s], senderMain, s)
  for s in 0 ..< nSenders:
    joinThread(senders[s])
  # `Actor.waitUntil {pred: ...}` — registered with the actor, evaluated on its
  # thread, no polling. The predicate reads `handled`, which only that thread
  # writes, so it is read where it lives.
  tuckWaitOn(slot, proc(): bool = handled >= total)
  let t = epochTime() - t0

  doAssert handled == total, "handled " & $handled & "/" & $total
  doAssert sum == total.int64, "sum " & $sum & " want " & $total

  echo "actor throughput: N=", total, " senders=", nSenders
  echo "  ", total, " msgs in ", (t*1000).formatFloat(ffDecimal,1), " ms  = ",
       (total.float/t/1e6).formatFloat(ffDecimal,2), " M msgs/sec"

main()
