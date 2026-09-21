## The Tuck runtime — ONE cooperative runtime expressing Tuck's OWN model
## (actor singletons, tasks, waitUntil, scheduler helpers) over arsenal as the
## engine. Codegen targets THESE names only; arsenal (coroutines + reactor) is
## the swappable engine, never exposed. The Odin runtime mirrors this same API
## over its own minicoro binding (compiler/tuckrt/tuck_coro.odin).
##
## TASKS are always coroutines on main's thread. ACTORS depend on the build's
## `--actors:MODE` (compiler/actor_mode.nim), which arrives here as a define:
##
##   thread (default)  one OS thread per actor. Real parallelism; a send
##                     crosses a thread boundary, so the mailbox is locked and
##                     an idle actor parks on a condvar.
##   single            every actor a coroutine on this thread, exactly like a
##                     task. Nothing races, so the mailbox lock compiles away
##                     and no thread is ever created — but main is not a
##                     coroutine, so it must lend its thread to the scheduler
##                     at `waitUntil` and at exit, or nothing ever runs (#8).
##   batch             thread-per-actor, but a send fills a batch owned by
##                     the SENDING thread and the whole batch crosses at
##                     once. The lock and the wake are paid once per batch,
##                     so this keeps real parallelism at close to single
##                     mode's cost — at the price of a rule: every point
##                     where a thread stops making progress must flush first.
##
## Every exported entry point below carries both shapes under
## `when TuckActorsSingle`. Read them in pairs.
##
## Build note: async Tuck programs MUST compile with
##   --stackTrace:off --lineTrace:off
## (Nim's stack-walker corrupts the switched coroutine stack otherwise.)
## No --path is needed anymore: the engine is vendored in ./tuck_coro.

import std/nativesockets
import std/locks
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

proc tuckStop*() =
  ## Ask the loop to return after the current pass, even if coroutines are
  ## still parked on fds.
  ##
  ## run() otherwise exits only when `waiters.len == 0`, so ONE coroutine
  ## parked on an fd that will never become readable keeps the process alive
  ## forever, spinning epoll_wait on an empty set. A server's accept loop is
  ## exactly that shape: it parks on the listening fd waiting for a client
  ## that may never arrive, and nothing else can end the program.
  ##
  ## Mirrors the Odin backend's tuckStop, which has always had this.
  if gLoop != nil: gLoop.stop()

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

const TuckActorsSingle* = defined(tuckActorsSingle)
  ## `--actors:single` (compiler/actor_mode.nim). Set by `tuck build` as
  ## `-d:tuckActorsSingle`, so the mode is a COMPILE-TIME fact for the whole
  ## program rather than a branch taken at run time. What that buys is the
  ## point of the mode: no thread is created, no condvar is waited on, and
  ## the mailbox's lock compiles to nothing (see tuck_rt.MailboxLock). A mode
  ## whose costs you still pay is not the mode you asked for.
  ##
  ## Every exported entry point below has both shapes. Read them in pairs:
  ## the `when TuckActorsSingle` arm is a coroutine on main's thread, the
  ## other is an OS thread of its own.

const TuckTestParkDelayMs* {.intdefine.} = 0
  ## See the test hook in actorMain. Never set in a real build.

when TuckTestParkDelayMs > 0:
  import std/os except sleep
  from std/os import sleep

const TuckActorsBatch* = defined(tuckActorsBatch)
  ## `--actors:batch`. Thread-per-actor as usual, but a `send` writes into a
  ## batch owned by the SENDING thread and the whole batch is handed over at
  ## once (tuck_rt). Everything below that concerns threads applies unchanged;
  ## what this adds is a rule.
  ##
  ## THE RULE: a message sitting in an unflushed batch is a deadlock, not a
  ## delay. So every point where this thread is about to stop making progress
  ## must flush first — before parking, before waiting on a predicate, and at
  ## exit. `tuckFlushStaged` below is that call, and the hook list under it is
  ## how a layer that cannot see the mailbox types reaches them anyway.

type
  FlushHook* = object
    ## One staging buffer's "hand over whatever you are holding". Registered
    ## by tuck_rt on first use, because the staging is a threadvar inside a
    ## generic and therefore has no name anything else can reach.
    ##
    ## Returns whether it actually handed anything over, which decides
    ## whether the wake below is needed at all.
    flush*: proc(p: pointer): bool {.nimcall, gcsafe.}
    data*: pointer

var gFlushHooks {.threadvar.}: seq[FlushHook]
  ## Per THREAD: each thread flushes only what it staged, which is why
  ## staging needs no lock of its own.

proc tuckRegisterFlush*(flush: proc(p: pointer): bool {.nimcall, gcsafe.},
                        data: pointer) =
  ## Called once per (thread, actor) the first time that thread stages for
  ## that actor.
  gFlushHooks.add FlushHook(flush: flush, data: data)


const
  ActorSpinMax* {.intdefine.} = 4096
    ## The most an actor will re-check its mailbox before parking.
  ActorSpinMin* {.intdefine.} = 16
    ## The least. Not zero: the budget has to stay big enough to notice that
    ## spinning has started paying again, or an actor that once went quiet
    ## could never earn its budget back.

# THE SPIN IS ADAPTIVE, and it has to be. A fixed budget is two different
# bets on two different workloads, and it cannot win both:
#
#   saturated actor   spinning always pays — the next message is already on
#                     its way, and parking would buy a futex round trip.
#   idle actor        spinning never pays, and the cost is not small.
#                     Measured, 8 mostly-idle actors at a 200us send gap: a
#                     fixed 2000-iteration spin burned 1.38 cores against
#                     0.37 for parking immediately — 3.7x the CPU to save
#                     12% of wall time. That is the exact "hundreds of light
#                     actors cost more than they return" pathology.
#
# So the budget is earned: doubled whenever a spin finds work, halved
# whenever it does not. A busy actor reaches ActorSpinMax and keeps its
# throughput; a quiet one decays to ActorSpinMin within a few parks and costs
# what parking costs (measured back down to 0.37 cores). The saturated case
# pays 8-11% for this against a fixed budget, which is the right side of the
# trade for a runtime that does not know the workload in advance.

# ONE OS THREAD PER ACTOR (ruled 2026-09-18).
#
# An actor is a daemon, and a daemon that only runs when `main` happens to
# yield is not one. Under the previous design every actor was a coroutine on
# main's thread, and main is NOT a coroutine — the emitted entry is a plain
# `quit(tuck_main())` — so nothing ever resumed them. `send` enqueued into a
# mailbox nobody drained, and a program without `scheduler::waitUntil` did
# nothing at all (#8). `waitUntil` was never a wait: it is
# `while not pred(): pumpOnce()`, i.e. main lending its thread to the
# scheduler, which is a workaround for the missing thread wearing the clothes
# of a synchronisation primitive.
#
# The runtime was already built for this. Every runtime global here is a
# {.threadvar.} — see THE CROSS-THREAD CONTRACT above — so a thread that calls
# tuckAsyncInit() gets its OWN scheduler and reactor, and the Mailbox has
# carried a Lock from the start with the comment "sends come from other
# threads". Nothing was missing but the thread.
#
# Tasks are unchanged: they stay coroutines on main's thread, where `[io]`
# means a cooperative yield. So the two constructs now differ in more than
# lifetime, which is the point — an actor is a service, a task is a job.
type
  Waiter = object
    ## One client waiting on one condition of one actor.
    ##
    ## The predicate is evaluated ON THE ACTOR'S THREAD, where the state is
    ## settled and unshared — so there is no external read to synchronise and
    ## no snapshot to be stale. Ada's protected-object entry barriers are the
    ## same construct for the same reason.
    pred: proc(): bool {.gcsafe.}
    doneFd: cint        ## one byte written when the predicate holds
    satisfied: bool     ## guarded by the owning slot's lock

  ActorSlot = object
    drain: DrainProc
    lock: Lock
    cond: Cond
    pending: bool       ## a send arrived; guarded by `lock`
    working: bool       ## draining right now, or woken and about to; `lock`
    parked: int         ## 1 while this actor is asleep on `cond`. ATOMIC, and
                        ## read without the lock: it is the whole fast path of
                        ## a send, so it must not be a global anything —
                        ## per-actor, so senders to different actors never
                        ## share the line.
    waiters: seq[ptr Waiter]   ## the registered predicates; guarded by `lock`
    thr: Thread[ptr ActorSlot]
    co: Coroutine       ## single mode only: this actor's coroutine. A raw
                        ## ptr, so it is safe in allocShared'd memory.
    queued: bool        ## single mode only: already in the ready queue, so a
                        ## send does not enqueue it a second time. One thread,
                        ## so no atomic.

var gMySlot {.threadvar.}: ptr ActorSlot
  ## The slot this thread serves, so the emitted drain can reach its waiters
  ## without carrying the slot through every generated proc. A threadvar, so
  ## each actor thread sees only its own.

var gActorSlots: seq[ptr ActorSlot]   ## SHARED, not a threadvar: tuckDrainActors
                                      ## has to reach every actor at exit
var gSlotsLock: Lock
var gSlotsReady = false

proc wakeAllParked() {.gcsafe.} = ({.cast(gcsafe).}:
  ## Wake every actor that is asleep. Used ONLY after a flush point handed
  ## something over — see tuckFlushStaged.
  ##
  ## Walks the list in place rather than copying it: this runs on an actor's
  ## own thread, where copying a shared seq is the GC-unsafe thing. Lock
  ## order is gSlotsLock then the slot's own, matching tuckDrainActors.
  acquire(gSlotsLock)
  for s in gActorSlots:
    if atomicLoadN(addr s.parked, ATOMIC_ACQUIRE) != 0:
      acquire(s.lock)
      s.pending = true
      signal(s.cond)
      release(s.lock)
  release(gSlotsLock))

proc tuckFlushStaged*() {.gcsafe.} = ({.cast(gcsafe).}:
  ## Hand over every batch this thread is holding, then make sure someone is
  ## awake to drain them.
  ##
  ## THE WAKE IS THE WHOLE REASON THIS IS NOT JUST A LOOP. An ordinary send
  ## is followed by the `tuckNotifySend` codegen emits, so a handover
  ## triggered by the batch filling up is already announced. A handover
  ## triggered HERE has no send behind it — the sends happened earlier and
  ## their notifies found the mailbox empty — so without this the batch lands
  ## in a mailbox whose actor is asleep and stays there. Found the honest
  ## way: an actor forwarding to a second actor printed nothing at all.
  ##
  ## Broadcast rather than targeted because a staging buffer does not know
  ## its actor's slot, and this runs once per park, not once per send. It is
  ## skipped entirely when nothing was staged, which is the common case.
  var handedOver = false
  for h in gFlushHooks:
    if h.flush(h.data): handedOver = true
  if handedOver: wakeAllParked())

# A COROUTINE NEVER MIGRATES BETWEEN THREADS, and that is now load-bearing.
#
# minicoro is multithread-safe (`mco_current_co` is MCO_THREAD_LOCAL and we do
# not define MCO_NO_MULTITHREAD), so two actor threads cannot stomp each
# other's current-coroutine. But minicoro's own documentation warns that a
# compiler may cache the ADDRESS of a thread-local, which goes stale if a
# coroutine resumes on a different thread — and this runtime reads threadvars
# (gLoop, globalScheduler, activeCoroutine) inside coroutine code constantly.
#
# Nothing migrates today: an actor's coroutines are created and resumed only on
# that actor's thread, main's tasks only on main's. There is no work stealing
# and no coroutine hand-off. If either is ever added, this is what breaks, and
# it will break as corruption rather than as a compile error.
proc checkWaiters(slot: ptr ActorSlot) =
  ## Evaluate every registered predicate and wake whoever is satisfied.
  ## ALWAYS called on the actor's own thread.
  ##
  ## The length check first is the "free when unused" property: an actor that
  ## nobody waits on pays one comparison per message, not a predicate call.
  if slot.waiters.len == 0: return
  var woken: seq[ptr Waiter]
  acquire(slot.lock)
  var kept: seq[ptr Waiter]
  for w in slot.waiters:
    if w.satisfied: continue
    if w.pred():
      w.satisfied = true
      woken.add(w)
    else:
      kept.add(w)
  slot.waiters = kept
  release(slot.lock)
  # Written OUTSIDE the lock: the waiter wakes immediately and must not
  # contend with the actor for a lock it is about to stop caring about.
  for w in woken:
    var b: byte = 1
    discard write(w.doneFd, addr b, 1)
    discard close(w.doneFd)

proc tuckCheckWaiters*() =
  ## Emitted in the drain loop after each handled message, so a predicate sees
  ## the EXACT moment it becomes true. Checking only once per drain pass would
  ## miss a condition that went true and false again inside one batch.
  ##
  ## Nothing to do in single mode: a waiter there is main, on this same
  ## thread, re-testing its own predicate between scheduler passes — there is
  ## no other thread to hand the answer to.
  when not TuckActorsSingle:
    if gMySlot != nil: checkWaiters(gMySlot)

proc actorMain(slot: ptr ActorSlot) {.thread.} =
  ## One actor, forever. Its own scheduler and reactor, so an `[io]` call in a
  ## handler suspends THIS actor and nothing else.
  ##
  ## Spins when the mailbox comes up empty — for as long as spinning has been
  ## paying — then blocks on a condvar. An actor alone on its thread has no
  ## peer to yield to, so the cooperative `coroYield` this replaced would have
  ## been an unbounded busy loop, while going straight to the condvar pays a
  ## futex round trip for a lull that usually ends in nanoseconds. The budget
  ## is what keeps both from being wrong for the other's workload.
  tuckAsyncInit()
  gMySlot = slot
  var spinBudget = ActorSpinMin   ## local: each actor earns its own
  while true:
    if slot.drain(): continue
    checkWaiters(slot)        # also after a pass that did nothing: a predicate
                              # registered while idle must be answered
    # Spin before committing to the park, for as long as spinning has been
    # paying (see ActorSpinMax above). A producer that is still running hands
    # over more work within a few hundred nanoseconds, while a park costs a
    # futex sleep here and a full wake path at the next sender — microseconds
    # against nanoseconds. Measured: an actor draining faster than one sender
    # refills runs dry ~168k times per million messages, and paying a futex
    # round trip for each is what made a "faster" mailbox 3x slower.
    #
    # `working` stays true throughout: a spinning actor has not given up, and
    # tuckDrainActors must not read it as quiescent while a message may still
    # be in flight.
    var gotWork = false
    for _ in 1 .. spinBudget:
      cpuRelax()
      if slot.drain():
        gotWork = true
        break
    if gotWork:
      spinBudget = min(spinBudget * 2, ActorSpinMax)
      continue
    spinBudget = max(spinBudget div 2, ActorSpinMin)
    # TEST HOOK, zero and inert unless -d:TuckTestParkDelayMs is given. It
    # widens the window between "this actor last looked and saw nothing" and
    # "this actor is marked parked", which is the race EV-7 lives in and is
    # a few instructions wide in a real build. A race you cannot make fail
    # on demand is a fix nobody can review.
    when TuckTestParkDelayMs > 0:
      sleep(TuckTestParkDelayMs)
    # About to stop making progress, so hand over anything this actor staged
    # for OTHER actors first. Without this a handler that sends and then goes
    # quiet holds its messages until the program next happens to run it, and
    # at exit `tuckDrainActors` would see a parked thread it cannot reach
    # into. Flushing before every park is what makes "a parked thread holds
    # nothing" true, and that is what lets exit be a local check.
    when TuckActorsBatch: tuckFlushStaged()
    # ARM, THEN LOOK AGAIN (EV-7). Publishing `parked` and then sleeping is
    # not enough: a sender that enqueued just before this store reads
    # `parked` as 0, returns without signalling, and its message sits in a
    # mailbox nobody will ever be woken for. Reproduced with
    # -d:TuckTestParkDelayMs widening the window — 1 send lost in 120.
    #
    # The recheck closes it from THIS side alone, leaving the sender's fast
    # path untouched. `drain` takes the mailbox spinlock, whose exchange is a
    # full barrier, so the arming store is globally visible before any send
    # that could follow it: either this drain sees that sender's message, or
    # that sender sees `parked` and signals.
    acquire(slot.lock)
    slot.working = false          # nothing left to do: visible to tuckDrainActors
    let mustPark = not slot.pending
    if mustPark:
      atomicStoreN(addr slot.parked, 1, ATOMIC_SEQ_CST)
    release(slot.lock)
    if mustPark and slot.drain():
      atomicStoreN(addr slot.parked, 0, ATOMIC_RELEASE)
      acquire(slot.lock)
      slot.working = true
      release(slot.lock)
      continue
    acquire(slot.lock)
    if not slot.pending:
      while not slot.pending:
        wait(slot.cond, slot.lock)
    atomicStoreN(addr slot.parked, 0, ATOMIC_RELEASE)
    slot.pending = false
    slot.working = true
    release(slot.lock)

proc tuckStartActor*(drain: DrainProc): pointer {.discardable.} =
  ## Register + start a declared actor (emitted once per actor, from the entry
  ## point before main runs).
  ##
  ## Returned as an OPAQUE pointer so the emitted registerActor<Name> can keep
  ## it without codegen needing the ActorSlot type: `Actor.waitUntil` and each
  ## `send` name the actor at the call site, so codegen needs a handle to pass
  ## and nothing more. Both modes return the same kind of handle, which is why
  ## neither the emitted code nor codegen knows which mode it is in.
  if not gSlotsReady:
    initLock(gSlotsLock)
    gSlotsReady = true
  let slot = cast[ptr ActorSlot](allocShared0(sizeof(ActorSlot)))
  slot.drain = drain
  when TuckActorsSingle:
    # A coroutine on main's thread. It drains, and when there is nothing left
    # it marks itself un-queued and hands control back; a send puts it in the
    # ready queue again. Nothing here is shared with another thread, so there
    # is no lock, no condvar and no wake syscall anywhere in the mode.
    slot.co = newCoroutine(proc() {.gcsafe.} = ({.cast(gcsafe).}:
      while true:
        if not slot.drain():
          slot.queued = false
          coroYield()), TuckStackSize)
    slot.queued = true
    gActorSlots.add(slot)
    schedule(slot.co)
  else:
    # An OS thread of its own. The slot is allocShared'd and the Thread lives
    # INSIDE it: a `seq` of Thread objects would move its elements on
    # reallocation, and a running thread's handle may not move.
    #
    # Detached by design. Actors are daemons with no termination condition, so
    # there is nothing to join — `quit` ends them.
    initLock(slot.lock)
    initCond(slot.cond)
    slot.pending = true      # drain once before the first wait: a send may
                             # already be queued by the time we get here
    slot.working = true
    acquire(gSlotsLock)
    gActorSlots.add(slot)
    release(gSlotsLock)
    createThread(slot.thr, actorMain, slot)
  cast[pointer](slot)

proc wakeSlot(s: ptr ActorSlot) {.inline.} =
  acquire(s.lock)
  s.pending = true
  signal(s.cond)
  release(s.lock)

proc tuckNotifySend*(handle: pointer) =
  ## Emitted by each send after enqueue, NAMING the actor it wrote to.
  ##
  ## THE FAST PATH IS THE POINT — this runs once per SEND. A busy actor comes
  ## back round its drain loop and finds the message by itself, so the common
  ## case must cost one relaxed read and nothing else. `parked` lives in that
  ## actor's own slot, so two senders to two different actors never touch the
  ## same line.
  ##
  ## It used to take no argument and therefore had to wake EVERY actor in the
  ## program behind a global lock, consulting a global counter to decide
  ## whether to bother: O(actors) per send, and the counter alone put a shared
  ## line in the path of every send in the program. The send site has always
  ## known which actor it was writing to; it just was not saying.
  if handle == nil: return       # not registered yet: nothing is parked
  let slot = cast[ptr ActorSlot](handle)
  when TuckActorsSingle:
    # Put the actor back in the ready queue, once. Without the guard a flood
    # of sends would queue the same coroutine a million times and the queue,
    # not the mailbox, would be what grew.
    if slot.queued: return
    slot.queued = true
    schedule(slot.co)
  else:
    if atomicLoadN(addr slot.parked, ATOMIC_ACQUIRE) == 0: return
    wakeSlot(slot)

proc pumpOnce(): bool   # forward: tuckWaitOn drives main's own tasks

proc tuckWaitOn*(handle: pointer, pred: proc(): bool) =
  ## `Actor.waitUntil {pred: :p}` — hand `pred` to that actor and block until it
  ## holds.
  ##
  ## Registration is a REGISTRATION, not a poll: the predicate goes into the
  ## actor's table and the actor evaluates it on its own thread after each
  ## message. The caller then does nothing at all until woken, so this costs no
  ## CPU, and the answer cannot be stale because it was computed where the
  ## state lives.
  ##
  ## `pending` is set so the actor wakes and evaluates ONCE IMMEDIATELY: the
  ## condition may already hold, and a waiter that registered against an
  ## already-true predicate must not sleep until the next unrelated message.
  ##
  ## SINGLE MODE answers the same question without any of that. The actor is a
  ## coroutine on this very thread, so there is no other thread to register
  ## with and nothing to synchronise: main drives the scheduler and re-tests
  ## the predicate between passes. It reads the actor's state directly because
  ## it IS the actor's thread. Note this drives rather than waits — if nothing
  ## on this thread can make the predicate true, nothing will.
  if handle == nil: return
  # EVERYTHING this thread staged, not just what it staged for `handle`: the
  # predicate may read another actor's state, and a message for that other
  # actor sitting in a batch here would make the condition unreachable.
  when TuckActorsBatch: tuckFlushStaged()
  when TuckActorsSingle:
    while not pred():
      discard pumpOnce()
    return
  let slot = cast[ptr ActorSlot](handle)
  var w = cast[ptr Waiter](allocShared0(sizeof(Waiter)))
  var fds: array[2, cint]
  discard pipe(fds)
  # The emitted predicate is an ordinary top-level proc and carries no gcsafe
  # annotation; it runs on the actor's thread, where the only thing it touches
  # is that actor's own state. Cast rather than demanding the annotation from
  # generated code that would have to acquire it for every user predicate.
  w.pred = cast[proc(): bool {.gcsafe.}](pred)
  w.doneFd = fds[1]
  acquire(slot.lock)
  slot.waiters.add(w)
  slot.pending = true
  signal(slot.cond)
  release(slot.lock)
  # Two waiting modes, the same fd.
  #
  # From a TASK: park through the reactor, exactly as tuckSubmitBlocking does.
  # Blocking the thread would freeze every other task on it.
  #
  # From MAIN: keep driving main's own tasks while waiting. A plain blocking
  # read here DEADLOCKS whenever the condition depends on a task — main's
  # thread is the only thing that runs tasks, so blocking it stops the very
  # work that would make the predicate true. std/net's echo round trip is
  # exactly that shape: a task serves the socket and an actor records the
  # result. The old spinning `waitUntil` never hit this because pumping was
  # all it did.
  var b: byte = 0
  if inCoroutine():
    tuckAwaitRead(fds[0].int)
    discard read(fds[0], addr b, 1)
  else:
    discard fcntl(fds[0], F_SETFL, O_NONBLOCK)
    while read(fds[0], addr b, 1) != 1:
      discard pumpOnce()   # runs a task, or polls the reactor for 1ms
  discard close(fds[0])
  deallocShared(w)

proc tuckDrainActors*() =
  ## Wait until every actor has emptied its mailbox. Emitted at the END of
  ## main, before the process exits.
  ##
  ## Without this, `send` is a coin flip: main enqueues and calls `quit`, and
  ## the actor's thread — detached, and possibly not yet scheduled by the OS —
  ## dies with the message still in the ring. A handler whose whole purpose is
  ## a side effect (printing, writing a file) then does nothing at all, which
  ## is the same observable bug thread-per-actor was meant to fix.
  ##
  ## This is NOT a join: actors are daemons and never finish. It waits for
  ## QUIESCENCE — no pending sends, nobody mid-handler — which is the strongest
  ## thing that is true of a system whose services outlive the program.
  ##
  ## It does NOT make `send` followed by a read of the actor's state ordered.
  ## That read happens inside main, long before this runs; no exit-time wait
  ## can reach back and change what it saw. `scheduler::waitUntil` remains the
  ## way to order a send against a read.
  ##
  ## SINGLE MODE is where this call stops being a safety net and becomes the
  ## thing that makes the mode work at all. Main is not a coroutine, so
  ## nothing has resumed the actors while main ran; every send so far only
  ## queued them. Draining here is main finally lending its thread to the
  ## scheduler, which is why a `send` with no `waitUntil` after it is still
  ## delivered (issue #8).
  # Main's own staged sends, which nothing else will ever flush.
  when TuckActorsBatch: tuckFlushStaged()
  if not gSlotsReady: return
  when TuckActorsSingle:
    # Run until nothing is ready: every mailbox is empty and no actor is
    # mid-handler. WEAKER than the thread-mode wait below in one case — an
    # actor suspended inside an `[io]` handler is not "ready", so if its fd
    # stays quiet this returns and the process exits with that handler
    # unfinished. `tuckRun()` (emitted whenever the program has tasks) is the
    # call that drives I/O to completion.
    while pumpOnce(): discard
  else:
    while true:
      var allIdle = true
      acquire(gSlotsLock)
      for s in gActorSlots:
        acquire(s.lock)
        if s.pending or s.working: allIdle = false
        release(s.lock)
      release(gSlotsLock)
      if allIdle: return
      cpuRelax()

proc pumpOnce(): bool =
  ## Advance the runtime one step: run a ready coroutine, or poll I/O. Returns
  ## true if progress was made.
  if hasPending():
    return runNext()
  discard gLoop.runOnce(1)
  hasPending()

proc runTasksUntil*(pred: proc(): bool) =
  ## `scheduler::runTasksUntil` — run THIS thread's coroutines until `pred`
  ## holds.
  ##
  ## It DRIVES; it does not wait. Every pumpOnce advances a task on this thread
  ## or polls this thread's reactor, so it can only make a condition true if
  ## something on this thread would make it true.
  ##
  ## It was called `waitUntil`, and once actors moved to their own threads that
  ## name was actively misleading: pumping main cannot advance an actor, so an
  ## actor predicate here degenerates into a busy-wait that merely LOOKS
  ## cooperative. `<Actor>.waitUntil` (tuckWaitOn) is the one that registers
  ## with the actor and blocks.
  while not pred():
    discard pumpOnce()

proc stop*() =
  ## `scheduler::stop` — the std name for tuckStop.
  tuckStop()
