## Bench 4 — the offload seam.
##
## A blocking operation cannot be made to yield: a regular file is always
## "ready" to epoll, so the reactor is structurally incapable of awaiting one.
## tuckSubmitBlocking runs the work off the scheduler thread and parks the
## calling coroutine on a completion pipe the reactor already watches.
##
## This measures whether that actually holds, because the failure mode is
## silent. If the seam ever reverts to running work on the scheduler thread,
## every program still produces correct ANSWERS — it just stops making progress
## while blocked. Exit codes cannot see that; a tick count can.
##
## Two questions:
##   1. Does the scheduler survive a blocking call? (ticks during 300ms)
##   2. What does one worker cost when calls overlap? (wall vs serial)
##
## Run via benches/run.sh, or:
##   nim c --opt:none --stackTrace:off --lineTrace:off --cc:clang --threads:on \
##     -o:bench_offload benches/bench_offload.nim && ./bench_offload

import std/[posix, times, strformat]
import ../compiler/tuck_async

const
  BlockMs = 300
  TickMs = 10
  IdealTicks = BlockMs div TickMs

var
  ticks = 0
  readDone = false
  callTook = 0.0
  doneCount = 0

proc blockingWork(arg: pointer) {.nimcall, gcsafe.} =
  ## Stands in for readLine/readFile. nanosleep is the honest model: it blocks
  ## the calling thread exactly the way read(2) on stdin or cold storage does,
  ## without needing a fixture that is genuinely slow.
  var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: BlockMs * 1_000_000)
  var rem: Timespec
  discard nanosleep(ts, rem)

proc measureTicks(offload: bool): int =
  ## Run a ticker beside one blocking call. The tick count IS the measurement:
  ## ~IdealTicks means the scheduler kept running, ~0 means it froze.
  ticks = 0
  readDone = false
  tuckAsyncInit()
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}:
    while not readDone:
      tuckSleep(TickMs)
      ticks.inc))
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}:
    let t0 = epochTime()
    if offload: tuckSubmitBlocking(blockingWork, nil)
    else: blockingWork(nil)
    callTook = (epochTime() - t0) * 1000
    readDone = true))
  tuckRun()
  ticks

proc measureConcurrent(n: int): float =
  ## N overlapping offloads against one worker. Expected: linear — that is the
  ## known ceiling of a single thread, and the number a pool would have to beat.
  doneCount = 0
  tuckAsyncInit()
  let t0 = epochTime()
  for i in 0 ..< n:
    tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}:
      tuckSubmitBlocking(blockingWork, nil)
      doneCount.inc))
  tuckRun()
  (epochTime() - t0) * 1000

when isMainModule:
  echo &"offload seam: {BlockMs}ms blocking work, a {TickMs}ms ticker beside it"
  echo &"  scheduler alive => ~{IdealTicks} ticks; scheduler frozen => ~0-1\n"

  let blocked = measureTicks(offload = false)
  echo &"  on-thread   ticks={blocked:<4} call={callTook:.0f}ms"
  let offloaded = measureTicks(offload = true)
  echo &"  offloaded   ticks={offloaded:<4} call={callTook:.0f}ms"

  echo ""
  if offloaded >= IdealTicks div 2 and blocked < IdealTicks div 4:
    echo &"  PASS  scheduler survives the block: {blocked} -> {offloaded} ticks"
  else:
    echo &"  FAIL  seam not working: {blocked} -> {offloaded} ticks"
    quit(1)

  echo &"\n  serialization (one worker, {BlockMs}ms each):"
  for n in [1, 2, 4]:
    let ms = measureConcurrent(n)
    let overhead = ms - float(n * BlockMs)
    echo &"    n={n}  wall={ms:.0f}ms  serial={n*BlockMs}ms  overhead={overhead:.0f}ms"
