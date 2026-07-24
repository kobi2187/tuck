## Tuck async runtime — a THIN, stable API over arsenal's engine.
## Codegen targets these names; arsenal is the swappable engine underneath.
## (Beef mirrors this same API over minicoro-beef.)
##
## Build note: async Tuck programs MUST compile with
##   --stackTrace:off --lineTrace:off  and  --path:<arsenal>/src
## (Nim's stack-walker corrupts the switched coroutine stack otherwise.)

import std/nativesockets
import arsenal/concurrency/coroutines/coroutine
import arsenal/concurrency/scheduler
import arsenal/io/eventloop

type
  TuckFd* = int | SocketHandle

var gLoop {.threadvar.}: EventLoop

proc tuckAsyncInit*() =
  ## Called once at the top of an async main, before spawning tasks.
  if gLoop == nil:
    gLoop = newEventLoop()

proc tuckSpawn*(fn: proc() {.closure, gcsafe.}) =
  ## Launch a task as a coroutine on the scheduler.
  discard spawn(fn)

proc tuckYield*() =
  ## Cooperative yield: reschedule this task and hand control back so other
  ## tasks make progress. The [io] yield point when there is no real fd yet.
  let self = running()
  if self != nil:
    schedule(self)
    coroYield()

proc tuckAwaitRead*(fd: TuckFd) =
  ## Suspend the current task until `fd` is readable (an [io] yield point).
  gLoop.waitForRead(fd)

proc tuckAwaitWrite*(fd: TuckFd) =
  ## Suspend the current task until `fd` is writable.
  gLoop.waitForWrite(fd)

proc tuckRun*() =
  ## Drive everything — scheduler + I/O reactor — until all tasks finish.
  ## Unifies arsenal's split scheduler/eventloop into one call.
  gLoop.run()
