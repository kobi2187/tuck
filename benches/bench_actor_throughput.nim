## Bench 2 — actor message throughput.
## One actor, N messages flooded into its mailbox, drained cooperatively.
## Mirrors exactly what codegen emits for an actor: a mailbox seq, a drain
## proc that empties it, tuckStartActor to run the loop, tuckNotifySend after
## each enqueue, and waitUntil on public state. Measures messages/sec end to
## end (enqueue + schedule + drain + handler).
##
## Run via benches/run.sh (builds with the arsenal path + coroutine flags).

import std/[times, os, strutils]
import ../compiler/tuck_async

# --- the "actor": public state + mailbox + drain (as codegen would emit) ---
var mailbox: seq[int]
var sum: int64
var handled: int

proc drain(): bool {.gcsafe.} = ({.cast(gcsafe).}:
  if mailbox.len == 0: return false
  for m in mailbox:      # handler: accumulate
    sum += m
    inc handled
  mailbox.setLen(0)
  result = true)

proc main() =
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 1_000_000

  tuckAsyncInit()
  tuckStartActor(drain)

  let t0 = epochTime()
  for i in 1 .. n:
    mailbox.add(i)          # `Actor send handler {payload}`
    tuckNotifySend()
  waitUntil(proc(): bool = handled >= n)
  let t = epochTime() - t0

  doAssert handled == n, "handled " & $handled & "/" & $n
  let want = n.int64 * (n.int64 + 1) div 2
  doAssert sum == want, "sum " & $sum & " want " & $want

  echo "actor throughput: N=", n
  echo "  ", n, " msgs in ", (t*1000).formatFloat(ffDecimal,1), " ms  = ",
       (n.float/t/1e6).formatFloat(ffDecimal,2), " M msgs/sec"

main()
