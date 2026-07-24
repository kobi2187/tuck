## Bench 1 — async runtime scale.
## Spawn N coroutines on arsenal's scheduler, each yields K times, then finishes.
## Measures: spawn throughput (coros/sec) and context-switch throughput
## (switches/sec = N*K total yields). Pure arsenal — the engine, no codegen.
##
## Run via benches/run.sh (builds with the arsenal path + coroutine flags).

import std/[times, os, strutils]
import ../compiler/tuck_async

proc main() =
  # NOTE ceiling: each coroutine owns a 256KB minicoro stack, so N live
  # coroutines reserve N*256KB. Spawn cost is dominated by that stack alloc
  # (~90us each), NOT scheduler enqueue (a Deque, O(1)). 10k default keeps the
  # footprint sane (~2.5GB peak reserved); switch throughput is the headline.
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 10_000
  let k = if paramCount() >= 2: parseInt(paramStr(2)) else: 100

  tuckAsyncInit()

  # --- spawn throughput ---
  var done = 0
  let tSpawn0 = epochTime()
  for i in 0 ..< n:
    tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}:
      for _ in 0 ..< k:
        tuckYield()
      inc done))
  let tSpawn = epochTime() - tSpawn0

  # --- drive to completion; time the switch storm ---
  let tRun0 = epochTime()
  tuckRun()
  let tRun = epochTime() - tRun0

  doAssert done == n, "only " & $done & "/" & $n & " coroutines finished"

  let switches = n.float * (k + 1).float   # k yields + 1 final schedule each
  echo "async scale: N=", n, " K=", k
  echo "  spawn:   ", n, " coros in ", (tSpawn*1000).formatFloat(ffDecimal,1),
       " ms  = ", (n.float/tSpawn/1e6).formatFloat(ffDecimal,2), " M coros/sec"
  echo "  run:     ", switches.int, " switches in ", (tRun*1000).formatFloat(ffDecimal,1),
       " ms  = ", (switches/tRun/1e6).formatFloat(ffDecimal,2), " M switches/sec"

main()
