## The Tuck runtime — ONE cooperative runtime expressing Tuck's OWN model
## (actor singletons, tasks, waitUntil, scheduler helpers) over arsenal as the
## engine. Codegen targets THESE names only; arsenal (coroutines + reactor) is
## the swappable engine, never exposed. The Odin runtime mirrors this same API
## over its own minicoro binding (compiler/tuckrt/tuck_coro.odin).
##
## Single-threaded + cooperative: actors and tasks are all coroutines on
## arsenal's scheduler. No OS threads — so no locks are needed on actor
## mailboxes (only one coroutine runs at a time; sends and drains never race).
##
## Build note: async Tuck programs MUST compile with
##   --stackTrace:off --lineTrace:off
## (Nim's stack-walker corrupts the switched coroutine stack otherwise.)
## No --path is needed anymore: the engine is vendored in ./tuck_coro.

import std/nativesockets
import ./tuck_coro

type
  TuckFd* = int | SocketHandle

var gLoop {.threadvar.}: EventLoop

const TuckStackSize* = 1024 * 1024
  ## Per-coroutine stack for tasks and actors. arsenal builds minicoro with
  ## MCO_USE_VMEM_ALLOCATOR (raw mmap), so this is a VIRTUAL reservation: only
  ## the pages a coroutine actually touches fault in (4KB at a time). A 1MB
  ## nominal stack therefore costs the same physical RAM as 128KB for shallow
  ## Tuck bodies — measured identical (40k coroutines: ~329MB RSS, 0.24M
  ## spawns/sec) — while removing the fixed-depth cap. Deep user recursion just
  ## faults more pages; it no longer overflows a small fixed stack.

proc tuckAsyncInit*() =
  ## Called once at the top of an async main, before spawning tasks.
  if gLoop == nil:
    gLoop = newEventLoop()

proc tuckSpawn*(fn: proc() {.closure, gcsafe.}) =
  ## Launch a task as a coroutine on the scheduler.
  schedule(newCoroutine(fn, TuckStackSize))

proc inCoroutine*(): bool =
  ## Are we on a coroutine, or in the main context? Spelled as a predicate
  ## because --threads:on brings system.running(Thread) into scope, and a bare
  ## `running()` in a module that also sees `Thread` loses overload resolution
  ## to it — a confusing error far from the cause.
  running() != nil

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

import std/posix

# --- the offload seam -------------------------------------------------------
#
# ONE interface, three possible backings. A blocking operation cannot be made
# to yield: a regular file is always "ready" to epoll, so the reactor is
# structurally incapable of awaiting it. libuv answers this with a thread pool;
# this is the same answer at the smallest size that removes the hang.
#
#   inline      call straight through — freestanding/embedded, where there is
#               one bare-metal loop and no scheduler to starve
#   one thread  what this file implements — serialized, an honest ceiling
#   pool        later, when a benchmark shows serialization is the bottleneck
#
# The seam is deliberately expressible in C: a function pointer, an opaque
# argument, and a completion fd. Nothing in it is Nim-shaped. The long-run plan
# is one C implementation bound from both backends over the existing FFI, so
# the two backends share semantics by construction rather than by mirroring.
#
# THE CROSS-THREAD CONTRACT. Every runtime global here is a {.threadvar.}
# (gLoop, globalScheduler, gActors) and tuck_coro's activeCoroutine is a raw
# ptr whose safety argument is single-threaded ownership. So the worker touches
# NONE of it:
#
#   The worker may touch only the request's own pointers, one libc/syscall,
#   and write() of one byte to the completion fd. It never calls running(),
#   schedule() or ready(), never allocates, and never dereferences a GC'd
#   string or seq.
#
# Everything crossing the boundary is caller-allocated and caller-freed. The
# parked coroutine's own stack keeps the request alive — it cannot proceed
# until the byte arrives, so there is no ownership question to resolve.

type
  BlockingFn* = proc(arg: pointer) {.nimcall, gcsafe.}
    ## The work itself. Runs on the blocking thread under the contract above.

  BlockingReq = object
    fn: BlockingFn
    arg: pointer
    doneFd: cint      ## write end of the caller's completion pipe

var
  gBlockingThread: Thread[void]
  gBlockingStarted = false
  gReqPipe: array[2, cint]   ## scheduler -> worker: one request at a time

proc blockingWorker() {.thread.} =
  ## Serve one request at a time, forever. Reads a whole BlockingReq off the
  ## request pipe (a pipe write of <= PIPE_BUF is atomic, so requests never
  ## interleave), runs it, then signals the caller's completion fd.
  while true:
    var req: BlockingReq
    let n = read(gReqPipe[0], addr req, sizeof(BlockingReq))
    if n != sizeof(BlockingReq): break   # pipe closed: the process is going down
    req.fn(req.arg)
    var b: byte = 1
    discard write(req.doneFd, addr b, 1)
    discard close(req.doneFd)

proc ensureBlockingThread() =
  ## Start the worker on first use. A program that never blocks never pays for
  ## a thread.
  if gBlockingStarted: return
  discard pipe(gReqPipe)
  createThread(gBlockingThread, blockingWorker)
  gBlockingStarted = true

proc tuckSubmitBlocking*(fn: BlockingFn, arg: pointer) =
  ## Run `fn(arg)` off the scheduler thread and SUSPEND this coroutine until it
  ## finishes. The scheduler, the reactor, every other actor and every timer
  ## keep running meanwhile — which is the whole point.
  ##
  ## Called from the main context (no coroutine), this runs the work inline:
  ## there is nothing to yield to, and parking would deadlock.
  if not inCoroutine():
    fn(arg)
    return
  ensureBlockingThread()
  var done: array[2, cint]
  discard pipe(done)
  var req = BlockingReq(fn: fn, arg: arg, doneFd: done[1])
  discard write(gReqPipe[1], addr req, sizeof(BlockingReq))
  tuckAwaitRead(done[0].int)   # the reactor resumes us when the byte lands
  var b: byte = 0
  discard read(done[0], addr b, 1)
  discard close(done[0])

# --- a demo async source ----------------------------------------------------
# A REAL non-blocking source: a pipe whose write end is fed by a writer
# coroutine after `ms` (a reactor-driven sleep, no OS thread — that would fight
# the coroutine GC). So the read fd genuinely becomes readable at `ms`, and a
# task racing `read fd` against a `timeout N` sees the true winner: data if
# ms < N (read arm), timeout if ms > N. This exercises real suspend/resume:
# the coroutine parks on the fd, the reactor sees it ready, resumes it.

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
        coroYield()), TuckStackSize)   # idle — hand control back; resumed on send
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
