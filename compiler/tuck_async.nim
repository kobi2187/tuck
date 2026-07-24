## The Tuck runtime — ONE cooperative runtime expressing Tuck's OWN model
## (actor singletons, tasks, waitUntil, scheduler helpers) over arsenal as the
## engine. Codegen targets THESE names only; arsenal (coroutines + reactor) is
## the swappable engine, never exposed. Beef mirrors this same API over
## minicoro-beef.
##
## Single-threaded + cooperative: actors and tasks are all coroutines on
## arsenal's scheduler. No OS threads — so no locks are needed on actor
## mailboxes (only one coroutine runs at a time; sends and drains never race).
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

proc tuckAwaitReadOrTimeout*(fd: TuckFd, timeoutMs: int): bool =
  ## Suspend until `fd` is readable OR timeoutMs elapses. true = readable,
  ## false = timed out. The operation-timeout primitive (spec §9.3).
  gLoop.waitForReadOrTimeout(fd, timeoutMs)

proc tuckSleep*(ms: int) =
  ## Cooperative sleep: suspend this coroutine for `ms`, driven by the reactor.
  gLoop.waitTimer(ms)

# --- a demo async source ----------------------------------------------------
# A REAL non-blocking source: a pipe whose write end is fed by a writer
# coroutine after `ms` (a reactor-driven sleep, no OS thread — that would fight
# the coroutine GC). So the read fd genuinely becomes readable at `ms`, and a
# task racing `read fd` against a `timeout N` sees the true winner: data if
# ms < N (read arm), timeout if ms > N. This exercises real suspend/resume:
# the coroutine parks on the fd, the reactor sees it ready, resumes it.
import std/posix

proc openSource*(ms: int): tuple[fd: int] =
  ## Open a pipe, arm a writer coroutine to feed one byte after `ms`, and
  ## return the read fd. The fd becomes readable at `ms` — a real async source.
  var fds: array[2, cint]
  discard pipe(fds)
  let wr = fds[1]
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}:
    tuckSleep(ms)
    var b: byte = 1
    discard write(wr, addr b, 1)
    discard close(wr)))
  (fd: fds[0].int)

proc tuckRun*() =
  ## Drive everything — scheduler + I/O reactor — until all tasks finish.
  ## Unifies arsenal's split scheduler/eventloop into one call.
  gLoop.run()

# --- task results ---------------------------------------------------------
# A task returns a value. `let r = {args} fetch` schedules fetch with a result
# slot; reading r awaits that slot. A TuckResult holds the eventual value and
# a done flag; the spawned task writes it, the caller waits on it.

type
  TuckAsyncResult*[T] = ref object
    value*: T
    done*: bool

proc newAsyncResult*[T](): TuckAsyncResult[T] =
  TuckAsyncResult[T](done: false)

proc spawnResult*[T](slot: TuckAsyncResult[T],
                     body: proc(): T {.closure, gcsafe.}) =
  ## Spawn a task whose return value lands in `slot`.
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}:
    slot.value = body()
    slot.done = true))

proc awaitResult*[T](slot: TuckAsyncResult[T]): T =
  ## Get a task's result. Inside a coroutine: yield until done. In the main
  ## (non-coroutine) context: drive the scheduler until done, then return.
  if running() != nil:
    while not slot.done: tuckYield()
  else:
    while not slot.done:
      if not runNext():
        discard gLoop.runOnce(1)   # let I/O + timers make progress
  slot.value

# --- actor runtime (spec §9) ----------------------------------------------
# An actor is a SINGLETON coroutine that loops: drain its mailbox, and when
# there is nothing to do, yield so other actors/tasks run. A send wakes the
# actor by rescheduling its coroutine. All cooperative on one thread — no
# locks, no OS thread. `waitUntil` (main side) drives the scheduler until a
# predicate over public actor state holds.

type DrainProc* = proc(): bool {.gcsafe.}   # drain my mailbox; did I work?

var gActors {.threadvar.}: seq[Coroutine]   # every declared actor's coroutine
var gPending {.threadvar.}: bool            # a send happened — an actor may work

proc tuckStartActor*(drain: DrainProc) =
  ## Register + start a declared actor as a looping coroutine (emitted once per
  ## actor). The loop drains, then yields when idle; a send reschedules it.
  let co = newCoroutine(proc() {.gcsafe.} = ({.cast(gcsafe).}:
    while true:
      let didWork = drain()
      if not didWork:
        coroYield()))            # idle — hand control back; resumed on send
  gActors.add(co)
  schedule(co)

proc tuckNotifySend*() =
  ## Emitted by each send after enqueue: mark work pending and reschedule idle
  ## actors so they drain on the next scheduler pass.
  gPending = true
  for co in gActors:
    if not co.isFinished():
      schedule(co)

proc pumpOnce(): bool =
  ## Advance the runtime one step: run a ready coroutine, or poll I/O. Returns
  ## true if progress was made.
  if hasPending():
    return runNext()
  discard gLoop.runOnce(1)
  hasPending()

proc waitUntil*(pred: proc(): bool) =
  ## Main blocks until the predicate over public actor state holds, driving the
  ## runtime cooperatively meanwhile. (Same drive as awaitResult from main.)
  while not pred():
    discard pumpOnce()
