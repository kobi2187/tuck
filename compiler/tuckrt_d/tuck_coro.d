// compiler/tuckrt_d/tuck_coro.d
//
// The D backend's coroutine engine, mirroring compiler/tuck_coro.nim and
// compiler/tuckrt/tuck_coro.odin in the same layers: minicoro bindings,
// coroutine wrapper, scheduler.
//
// ALL THREE BACKENDS DRIVE THE SAME VENDORED C LIBRARY
// (compiler/vendor/minicoro/minicoro.h, prebuilt as minicoro.a). That is the
// portable-runtime rule in practice: a program's concurrency semantics AND
// its performance shape must not depend on which backend built it, so the
// engine is shared rather than reimplemented per target. A large behavioural
// gap between backends is a porting bug, not a language difference.
//
// Verified before this file existed: a probe drove create / resume / yield /
// status from D against this same archive, and a coroutine suspended
// mid-body and resumed correctly.
//
// Linux only, like the Odin runtime.
module tuck_coro;

import core.stdc.stdlib : abort;
import std.stdio : stderr;
import core.sys.posix.unistd : read, write, close, pipe2, pipe;
import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.sys.linux.epoll;
// druntime moved this module: older releases expose it as
// core.sys.linux.timerfd, newer ones as core.sys.linux.sys.timerfd. Pinning
// either spelling makes the D backend refuse to build on half the
// toolchains, and the failure reads as "unable to read module `timerfd`"
// with nothing to say which half you are on.
static if (__traits(compiles, { import core.sys.linux.sys.timerfd; }))
    import core.sys.linux.sys.timerfd;
else
    import core.sys.linux.timerfd;
import core.sys.posix.time : CLOCK_MONOTONIC, itimerspec;

// ===========================================================================
// minicoro bindings
// ===========================================================================

extern (C):

struct McoCoro;   // opaque — minicoro owns the layout

struct McoDesc
{
    void function(McoCoro*) func;
    void* user_data;
    void* alloc_cb;
    void* dealloc_cb;
    void* allocator_data;
    size_t storage_size;
    size_t coro_size;
    size_t stack_size;
}

McoDesc mco_desc_init(void function(McoCoro*) func, size_t stack_size);
int mco_create(McoCoro** out_co, McoDesc* desc);
int mco_destroy(McoCoro* co);
int mco_resume(McoCoro* co);
int mco_yield(McoCoro* co);
int mco_status(McoCoro* co);
McoCoro* mco_running();
void* mco_get_user_data(McoCoro* co);

enum MCO_SUCCESS = 0;
enum MCO_DEAD = 0;

extern (D):

/// Per-coroutine stack. minicoro is built with a raw-mmap allocator, so this
/// is a VIRTUAL reservation: only touched pages fault in. Matches
/// tuck_async.nim's TuckStackSize and the Odin runtime's, so all three have
/// the same recursion headroom.
enum TuckStackSize = 1024 * 1024;

// ===========================================================================
// Coroutine wrapper
// ===========================================================================

enum CoroutineState : ubyte
{
    Ready,      /// created but never resumed
    Running,
    Suspended,  /// yielded, waiting to be resumed
    Finished,
}

struct Coroutine
{
    McoCoro* handle;
    void delegate() entryPoint;
    CoroutineState state;
}

// PER THREAD, not per program. Each actor runs on its own OS thread with its
// own scheduler and reactor (spec 9.1). D module-level variables are already
// thread-local BY DEFAULT — `__gshared` is what opts out — so removing it is
// what makes these per-thread. Sharing them would have each actor thread
// resuming another's coroutine.
private Coroutine* activeCoroutine;  /// null in the main context

Coroutine* running() { return activeCoroutine; }

bool inCoroutine() { return activeCoroutine !is null; }

bool isFinished(Coroutine* c)
{
    return c is null || c.state == CoroutineState.Finished;
}

private void tuckCoroFail(string what)
{
    stderr.writeln("tuck: ", what);
    abort();
}

/// C -> D bridge. An extern(C) function has no D context to restore (unlike
/// Odin, which must carry one), so this is simply the entry point plus the
/// finished marker.
private extern (C) void trampoline(McoCoro* mc)
{
    auto co = cast(Coroutine*) mco_get_user_data(mc);
    if (co.entryPoint !is null)
        co.entryPoint();
    co.state = CoroutineState.Finished;
}

Coroutine* newCoroutine(void delegate() fn, size_t stackSize = TuckStackSize)
{
    import core.stdc.stdlib : malloc;
    auto co = cast(Coroutine*) malloc(Coroutine.sizeof);
    if (co is null) tuckCoroFail("out of memory creating a coroutine");
    *co = Coroutine.init;
    co.entryPoint = fn;
    co.state = CoroutineState.Ready;
    // mco_desc_init fills coro_size/alignment/allocator internals that
    // mco_create validates; a hand-zeroed desc fails with INVALID_ARGUMENTS.
    auto desc = mco_desc_init(&trampoline, stackSize);
    desc.user_data = cast(void*) co;
    if (mco_create(&co.handle, &desc) != MCO_SUCCESS)
        tuckCoroFail("failed to create coroutine");
    return co;
}

/// Run a coroutine until it yields or finishes. Nested resumes are allowed:
/// the previous active coroutine is restored on the way out.
void resume(Coroutine* c)
{
    if (c is null || c.state == CoroutineState.Finished) return;
    auto prev = activeCoroutine;
    activeCoroutine = c;
    c.state = CoroutineState.Running;
    mco_resume(c.handle);
    activeCoroutine = prev;
    if (mco_status(c.handle) == MCO_DEAD)
        c.state = CoroutineState.Finished;
    else
        c.state = CoroutineState.Suspended;
}

/// Suspend the running coroutine. Outside one this is a no-op rather than a
/// crash: `main` is not a coroutine, and a [io] call there simply proceeds.
void suspend()
{
    if (activeCoroutine is null) return;
    mco_yield(mco_running());
}

void destroyCoroutine(Coroutine* c)
{
    import core.stdc.stdlib : free;
    if (c is null) return;
    if (c.handle !is null) mco_destroy(c.handle);
    free(c);
}

// ===========================================================================
// Scheduler
// ===========================================================================
//
// One cooperative run queue on one thread (spec §9.4): no preemption, one
// resume per tick. Tasks and actors are both coroutines on this queue.

// The run queue is MALLOC'd, not GC memory, and this is load-bearing.
//
// D's GC scans thread stacks conservatively. A coroutine runs on a minicoro
// stack the GC was never told about, so a collection triggered from inside
// one walks a stack it does not know and crashes — observed as a segfault
// with a 0xdeaddeaddeaddead frame under gdb, at ~10k coroutines, which is
// exactly where an append reallocated and tripped a collection.
//
// Appending to a GC array from a coroutine is therefore unsafe by
// construction. A hand-managed ring avoids allocating on the coroutine
// stack path entirely. (Nim disables its stack-walker for the same reason —
// tuck_async.nim's mandatory --stackTrace:off; Odin has no GC and needs
// neither.)
private Coroutine** readyQueue;
private size_t readyHead;   /// next to run
private size_t readyTail;   /// next free slot
private size_t readyCap;
private bool stopped;

private void growQueue()
{
    import core.stdc.stdlib : realloc;
    size_t newCap = readyCap == 0 ? 64 : readyCap * 2;
    auto p = cast(Coroutine**) realloc(readyQueue,
                                       newCap * (Coroutine*).sizeof);
    if (p is null) tuckCoroFail("out of memory growing the run queue");
    readyQueue = p;
    readyCap = newCap;
}

private size_t readyCount() { return readyTail - readyHead; }

/// Put a coroutine on the run queue.
void schedule(Coroutine* c)
{
    if (c is null || c.state == CoroutineState.Finished) return;
    if (readyTail == readyCap)
    {
        // Reclaim the consumed prefix before growing: a long-running program
        // would otherwise walk the buffer forever.
        if (readyHead > 0)
        {
            import core.stdc.string : memmove;
            memmove(readyQueue, readyQueue + readyHead,
                    readyCount * (Coroutine*).sizeof);
            readyTail -= readyHead;
            readyHead = 0;
        }
        if (readyTail == readyCap) growQueue();
    }
    readyQueue[readyTail++] = c;
}

private Coroutine* takeReady()
{
    if (readyCount == 0) return null;
    return readyQueue[readyHead++];
}

/// Create a coroutine for `fn` and queue it. The Tuck-facing spawn.
Coroutine* spawn(void delegate() fn)
{
    auto c = newCoroutine(fn);
    schedule(c);
    return c;
}

/// Yield to the scheduler: the current coroutine goes back on the queue and
/// suspends, so anything else ready makes progress.
void tuckYield()
{
    auto c = activeCoroutine;
    if (c is null) return;   // main context: nothing to yield to
    schedule(c);
    suspend();
}

// ===========================================================================
// Event loop / reactor  (epoll + timerfd; mirrors tuckrt/tuck_coro.odin)
// ===========================================================================
//
// druntime ships real bindings for both syscalls (core.sys.linux.epoll,
// core.sys.linux.sys.timerfd) — no foreign-C declarations needed, unlike
// Odin which hand-declares the six calls itself.
//
// The ring-buffer scheduler above never auto-requeues a coroutine that
// suspends: `tuckYield` re-schedules itself before suspending, and
// `parkCurrent` below deliberately does not, leaving the reactor as the
// only thing that puts a parked coroutine back on the queue. Odin's
// scheduler runs on a generic `queue.Queue` whose runNext always requeues
// on the way out, so it needs an explicit `parked` set to suppress that for
// an I/O-waiting coroutine. This ring buffer needs no such set — the
// "don't requeue automatically" behaviour Odin has to opt into is simply
// how this scheduler already works.

private struct IoWaiter
{
    Coroutine* coro;
    bool isTimer;
}

private struct EventLoop
{
    int epfd = -1;
    IoWaiter[int] waiters;   // fd -> who is parked on it
    bool inited;
}

private EventLoop gLoop;

private void initLoop()
{
    if (gLoop.inited) return;
    gLoop.epfd = epoll_create1(0);
    if (gLoop.epfd < 0) tuckCoroFail("epoll_create1 failed");
    gLoop.inited = true;
}

private void parkCurrent(int fd, bool isTimer)
{
    auto c = activeCoroutine;
    if (c is null) tuckCoroFail("cannot await outside a coroutine");
    gLoop.waiters[fd] = IoWaiter(c, isTimer);
    suspend();
}

/// Arm a one-shot timerfd for `ms` milliseconds and register it with epoll.
/// Returns false (leaving `tfd` unset) on any syscall failure.
private bool armTimer(out int tfd, long ms)
{
    tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    if (tfd < 0) return false;
    itimerspec spec;
    spec.it_value.tv_sec = cast(typeof(spec.it_value.tv_sec))(ms / 1000);
    spec.it_value.tv_nsec =
        cast(typeof(spec.it_value.tv_nsec))((ms % 1000) * 1_000_000);
    if (timerfd_settime(tfd, 0, &spec, null) != 0)
    {
        close(tfd);
        return false;
    }
    epoll_event ev;
    ev.events = EPOLLIN;
    ev.data.fd = tfd;
    if (epoll_ctl(gLoop.epfd, EPOLL_CTL_ADD, tfd, &ev) != 0)
    {
        close(tfd);
        return false;
    }
    return true;
}

private bool watchFd(int fd, bool write_)
{
    epoll_event ev;
    ev.events = write_ ? EPOLLOUT : EPOLLIN;
    ev.data.fd = fd;
    return epoll_ctl(gLoop.epfd, EPOLL_CTL_ADD, fd, &ev) == 0;
}

private void unwatch(int fd, bool isTimer)
{
    epoll_ctl(gLoop.epfd, EPOLL_CTL_DEL, fd, null);
    gLoop.waiters.remove(fd);
    if (isTimer) close(fd);
}

/// Suspend until `fd` is readable.
void tuckAwaitRead(long fd)
{
    initLoop();
    auto ifd = cast(int) fd;
    if (!watchFd(ifd, false)) return;
    parkCurrent(ifd, false);
    unwatch(ifd, false);
}

void tuckAwaitWrite(long fd)
{
    initLoop();
    auto ifd = cast(int) fd;
    if (!watchFd(ifd, true)) return;
    parkCurrent(ifd, true);
    unwatch(ifd, false);
}

/// Cooperative sleep: suspend this coroutine for `ms`, driven by the reactor.
void tuckSleep(long ms)
{
    initLoop();
    int tfd;
    if (!armTimer(tfd, ms)) return;
    parkCurrent(tfd, true);
    unwatch(tfd, true);
}

/// Suspend until `fd` is readable OR timeoutMs elapses. Returns true if
/// readable, false if it timed out — the operation-timeout primitive
/// (spec §9.3). Whichever side loses the race is torn down here; leaving it
/// registered would later wake a coroutine that has moved on.
bool tuckAwaitReadOrTimeout(long fd, long timeoutMs)
{
    initLoop();
    auto rfd = cast(int) fd;
    if (!watchFd(rfd, false)) return false;
    int tfd;
    if (!armTimer(tfd, timeoutMs))
    {
        unwatch(rfd, false);
        return false;
    }

    auto c = activeCoroutine;
    if (c is null) tuckCoroFail("cannot await outside a coroutine");
    gLoop.waiters[rfd] = IoWaiter(c, false);
    gLoop.waiters[tfd] = IoWaiter(c, true);
    suspend();

    // Exactly one side fired and was removed by runOnce; whichever is still
    // registered lost the race.
    bool readable = (rfd !in gLoop.waiters);
    unwatch(rfd, false);
    unwatch(tfd, true);
    return readable;
}

/// Process one batch of events. Returns true if anything was resumed.
private bool runOnce(int timeoutMs = 100)
{
    initLoop();
    epoll_event[64] events;
    int n = epoll_wait(gLoop.epfd, events.ptr, 64, timeoutMs);
    if (n <= 0) return false;

    // A read racing a timeout can land BOTH sides in one batch, so a
    // coroutine already resumed in this pass must not be queued twice.
    bool[Coroutine*] resumed;
    foreach (i; 0 .. n)
    {
        int fd = events[i].data.fd;
        auto wp = fd in gLoop.waiters;
        if (wp is null) continue;
        auto w = *wp;
        gLoop.waiters.remove(fd);
        if (w.coro !in resumed)
        {
            resumed[w.coro] = true;
            schedule(w.coro);
        }
    }
    return true;
}

/// Run one coroutine off the ready queue, reaping it if it finished.
private void stepOne()
{
    auto c = takeReady();
    resume(c);
    if (c.state == CoroutineState.Finished) destroyCoroutine(c);
}

/// Run until nothing is ready AND nothing is waiting on the reactor.
void tuckRun()
{
    initLoop();
    stopped = false;
    while (!stopped)
    {
        while (readyCount > 0) stepOne();
        // Checked AFTER the drain so a coroutine that called stop() in this
        // pass is honoured immediately, rather than after another 100ms
        // parked in epoll_wait.
        if (stopped) break;
        if (gLoop.waiters.length == 0 && readyCount == 0) break;
        runOnce(100);
    }
}

void tuckStop() { stopped = true; }

void tuckAsyncInit()
{
    readyHead = 0;
    readyTail = 0;
    stopped = false;
    initLoop();
}

/// Fire-and-forget: schedule a task, do not wait for it (spec §9.2).
void tuckSpawn(void delegate() fn) { cast(void) spawn(fn); }

// ===========================================================================
// The offload seam  (mirrors tuckrt/tuck_coro.odin's tuckSubmitBlocking)
// ===========================================================================
//
// A blocking operation cannot be made to yield: a regular file is always
// "ready" to epoll, so the reactor is structurally incapable of awaiting one.
// The work runs on a worker thread and signals completion by writing one byte
// to a pipe the reactor already watches, which resumes the parked coroutine.
//
// `fn`/`arg` are a raw C-style callback, not a delegate: `arg` is a caller-
// owned MALLOC'd request (see tuck_rt.d's FileReq), never a GC pointer whose
// only live reference sits on the calling coroutine's minicoro stack — that
// stack is not GC-scanned (same reason the ready queue above is malloc'd,
// not a GC array), so nothing here may hand the worker a bare `new`'d
// object and expect it to survive a collection while the coroutine is
// parked. The worker thread ITSELF is safe to allocate GC memory on (D's
// Thread registers with the collector), but the boundary crossing is not.
alias BlockingFn = void function(void*);

private struct BlockingReq
{
    BlockingFn fn;
    void* arg;
    int doneFd;
}

private __gshared bool gBlockingStarted;
private __gshared int[2] gReqPipe;

private void blockingWorker()
{
    while (true)
    {
        BlockingReq req;
        auto buf = (cast(ubyte*)&req)[0 .. BlockingReq.sizeof];
        auto n = read(gReqPipe[0], buf.ptr, buf.length);
        if (n != cast(ptrdiff_t) buf.length) break;
        req.fn(req.arg);
        ubyte[1] b = [1];
        write(req.doneFd, b.ptr, 1);
        close(req.doneFd);
    }
}

private void ensureBlockingThread()
{
    // Started on first use: a program that never blocks never pays for a
    // thread. One worker, process lifetime, never joined — it parks in
    // read() on the request pipe when idle. `isDaemon` so it never keeps
    // the process alive on its own.
    if (gBlockingStarted) return;
    int[2] fds;
    if (pipe2(fds, 0) != 0) return;
    gReqPipe = fds;
    import core.thread : Thread;
    auto th = new Thread(&blockingWorker);
    th.isDaemon = true;
    th.start();
    gBlockingStarted = true;
}

/// Run `fn(arg)` off the scheduler thread and SUSPEND this coroutine until it
/// finishes. The scheduler, the reactor, every actor and every timer keep
/// running meanwhile.
///
/// Called outside a coroutine this runs inline: there is nothing to yield to,
/// and parking would deadlock.
void tuckSubmitBlocking(BlockingFn fn, void* arg)
{
    if (activeCoroutine is null)
    {
        fn(arg);
        return;
    }
    initLoop();
    ensureBlockingThread();
    if (!gBlockingStarted)
    {
        fn(arg);   // no worker: better inline than not at all
        return;
    }
    int[2] done;
    if (pipe2(done, 0) != 0)
    {
        fn(arg);
        return;
    }
    auto req = BlockingReq(fn, arg, done[1]);
    auto buf = (cast(ubyte*)&req)[0 .. BlockingReq.sizeof];
    write(gReqPipe[1], buf.ptr, buf.length);
    tuckAwaitRead(done[0]);   // the reactor resumes us when the byte lands
    ubyte[1] b;
    read(done[0], b.ptr, 1);
    close(done[0]);
}

// ===========================================================================
// Task results
// ===========================================================================
//
// Calling a task SCHEDULES it; binding its result AWAITS completion, and at
// the call site that reads exactly like a synchronous call (spec §9.2).

/// One task's result slot.
final class TuckAsyncResult(T)
{
    T value;
    bool done;
}

TuckAsyncResult!T newAsyncResult(T)()
{
    return new TuckAsyncResult!T();
}

/// Schedule `fn`, storing its result in `slot` when it finishes.
void spawnResult(T)(TuckAsyncResult!T slot, T delegate() fn)
{
    tuckSpawn({
        slot.value = fn();
        slot.done = true;
    });
}

/// Wait for a task's result.
///
/// Inside a coroutine: yield until it lands, so everything else keeps
/// running. In the MAIN context there is nothing to yield to, so drive the
/// scheduler directly — `main` is a plain fn, not a coroutine, and this is
/// what lets a task's result be bound there at all. Mirrors
/// tuck_async.nim's awaitResult.
T awaitResult(T)(TuckAsyncResult!T slot)
{
    while (!slot.done)
    {
        if (inCoroutine())
            tuckYield();
        else if (readyCount > 0)
            stepOne();
        else
            runOnce(1);
    }
    return slot.value;
}

// ===========================================================================
// Actors
// ===========================================================================
//
// An actor here is NOT an Erlang process. It is a SINGLETON SERVICE: one per
// declared type, no construction and no reference, registered automatically
// and alive for the whole program — it exits when the program does. It owns
// its state and drains a mailbox; `send` is fire-and-forget with no reply
// channel, and a caller that wants a value polls a public field through
// waitUntil.

/// Drain my mailbox; did I do any work?
///
/// A FUNCTION pointer, not a delegate: an actor is a singleton, so its drain
/// is a free function over the module-level instance and captures nothing.
/// D distinguishes the two types, and the emitted `&drain_X` is the former.
alias DrainProc = bool function();

// ONE OS THREAD PER ACTOR (ruled 2026-09-18) — the Nim twin carries the full
// reasoning. An actor is a daemon, and a daemon that only runs when main
// happens to yield is not one: a program with no wait never delivered a
// message at all (#8).

private struct Waiter
{
    bool function() pred;
    int doneFd;          /// one byte written when the predicate holds
    bool satisfied;
}

private struct ActorSlot
{
    DrainProc drain;
    Mutex lock;
    Condition cond;
    bool pending;
    bool working;
    shared bool parked;   /// asleep on `cond`. Read WITHOUT the lock: it is
                          /// the whole fast path of a send, so it must be
                          /// per-actor rather than a global anything.
    bool retiring;        /// set once, at exit: leave the loop, do not park
    Thread thread;        /// kept so the exit drain can join it
    Waiter*[] waiters;
}

private __gshared ActorSlot*[] gActorSlots;  /// SHARED: tuckDrainActors has
private __gshared Mutex gSlotsLock;          /// to reach every actor at exit

/// How far an idle actor re-checks its mailbox before parking. Adaptive,
/// because a fixed budget is two bets on two workloads and cannot win both:
/// spinning always pays for a saturated actor and never for an idle one.
/// Measured on the Nim runtime, 8 light actors: a fixed 2000-iteration spin
/// burned 1.38 cores against 0.37 for parking at once. Doubled on a hit,
/// halved on a park, floored low enough to be noise.
private enum ActorSpinMax = 4096;
private enum ActorSpinMin = 16;

private ActorSlot* gMySlot;                  /// per thread: the slot it serves

private void checkWaiters(ActorSlot* slot)
{
    // Evaluate every registered predicate and wake whoever is satisfied.
    // ALWAYS on the actor's own thread, where the state is settled.
    // The length check first is the "free when unused" property.
    if (slot.waiters.length == 0) return;
    Waiter*[] woken;
    Waiter*[] kept;
    slot.lock.lock();
    foreach (w; slot.waiters)
    {
        if (w.satisfied) continue;
        if (w.pred()) { w.satisfied = true; woken ~= w; }
        else kept ~= w;
    }
    slot.waiters = kept;
    slot.lock.unlock();
    // Outside the lock: the waiter wakes at once and must not contend for a
    // lock it is about to stop caring about.
    foreach (w; woken)
    {
        ubyte b = 1;
        write(w.doneFd, &b, 1);
        close(w.doneFd);
    }
}

/// Emitted in the drain loop after each handled message, so a predicate sees
/// the EXACT moment it becomes true rather than once per batch.
void tuckCheckWaiters()
{
    if (gMySlot !is null) checkWaiters(gMySlot);
}

private void actorMain(ActorSlot* slot)
{
    tuckAsyncInit();          // this thread's own scheduler and reactor
    gMySlot = slot;
    int spinBudget = ActorSpinMin;   // each actor earns its own
    while (true)
    {
        if (slot.drain()) continue;
        checkWaiters(slot);
        // Spin for as long as spinning has been paying. A producer that is
        // still running hands over more work within nanoseconds, while a
        // park costs a futex sleep here and a wake at the next sender.
        // `working` stays true throughout: a spinning actor has not given
        // up, and tuckDrainActors must not read it as quiescent.
        bool gotWork = false;
        foreach (_; 0 .. spinBudget)
        {
            if (slot.drain()) { gotWork = true; break; }
        }
        if (gotWork)
        {
            spinBudget = spinBudget * 2 > ActorSpinMax ? ActorSpinMax
                                                       : spinBudget * 2;
            continue;
        }
        spinBudget = spinBudget / 2 < ActorSpinMin ? ActorSpinMin
                                                   : spinBudget / 2;
        // ARM, THEN LOOK AGAIN (EV-7). Publishing `parked` and then sleeping
        // is not enough: a sender that enqueued just before that store reads
        // `parked` as false, returns without signalling, and its message sits
        // in a mailbox nobody will be woken for. Reproduced on the Nim twin
        // with the window widened — 1 send lost in 120. The recheck closes it
        // from THIS side alone, leaving the sender's fast path untouched: the
        // drain takes the mailbox spinlock, whose exchange is a full barrier,
        // so the arming store is visible before any send that could follow.
        slot.lock.lock();
        slot.working = false;
        immutable mustPark = !slot.pending;
        if (mustPark) atomicStore(slot.parked, true);
        slot.lock.unlock();
        if (mustPark && slot.drain())
        {
            atomicStore(slot.parked, false);
            slot.lock.lock();
            slot.working = true;
            slot.lock.unlock();
            continue;
        }
        slot.lock.lock();
        while (!slot.pending && !slot.retiring) slot.cond.wait();
        if (slot.retiring)
        {
            slot.lock.unlock();
            return;
        }
        atomicStore(slot.parked, false);
        slot.pending = false;
        slot.working = true;
        slot.lock.unlock();
    }
}

/// Register and start a declared actor on its own OS thread.
///
/// Detached by design: actors are daemons with no termination condition, so
/// there is nothing to join. The process exits and they go with it.
void* tuckStartActor(DrainProc drain)
{
    if (gSlotsLock is null) gSlotsLock = new Mutex();
    auto slot = new ActorSlot();
    slot.drain = drain;
    slot.lock = new Mutex();
    slot.cond = new Condition(slot.lock);
    slot.pending = true;      // drain once before the first wait: a send may
    slot.working = true;      // already be queued by the time we get here
    gSlotsLock.lock();
    gActorSlots ~= slot;
    gSlotsLock.unlock();
    auto t = new Thread({ actorMain(slot); });
    // Daemon still: an uncaught throw out of main tears the runtime down
    // without passing tuckDrainActors, and a non-daemon thread would hang
    // that exit forever instead.
    t.isDaemon = true;
    slot.thread = t;
    t.start();
    return cast(void*) slot;
}

/// `Actor.waitUntil {pred: :p}` — register with THAT actor and block. The
/// predicate is evaluated on the actor's thread, so the answer is neither
/// racy nor stale.
void tuckWaitOn(void* handle, bool function() pred)
{
    if (handle is null) return;
    auto slot = cast(ActorSlot*) handle;
    auto w = new Waiter();
    w.pred = pred;
    int[2] fds;
    pipe(fds);
    w.doneFd = fds[1];
    slot.lock.lock();
    slot.waiters ~= w;
    slot.pending = true;      // evaluate ONCE IMMEDIATELY: it may already hold
    slot.cond.notify();
    slot.lock.unlock();
    // From a TASK: park through the reactor — blocking the thread would freeze
    // every other task on it.
    //
    // From MAIN: keep driving main's own tasks while waiting. A plain blocking
    // read DEADLOCKS whenever the condition depends on a task, because main's
    // thread is the only thing that runs tasks and blocking it stops the very
    // work that would make the predicate true.
    ubyte b = 0;
    if (inCoroutine())
    {
        tuckAwaitRead(fds[0]);
        read(fds[0], &b, 1);
    }
    else
    {
        fcntl(fds[0], F_SETFL, O_NONBLOCK);
        while (read(fds[0], &b, 1) != 1)
        {
            if (readyCount > 0) stepOne();
            else runOnce(1);
        }
    }
    close(fds[0]);
}

/// Wait for every actor to empty its mailbox, then retire its thread.
/// Emitted at the END of main: without it `send` races teardown, since the
/// actor thread is detached and may never have been scheduled.
///
/// THE RETIRE IS D'S ALONE. Returning from D's main runs rt_term, whose
/// gc_term collects — suspending every registered thread by signal — and
/// then unmaps the GC heap. A parked actor lives in that heap: its slot,
/// its Mutex and Condition, its Thread object. Unmapping them under a
/// thread still in pthread_cond_wait crashed about half of all two-actor
/// runs, as "The futex facility returned an unexpected error code" or a
/// segfault in thread_postSuspend. Nim and Odin exit without tearing down a
/// heap, so their twins wait for quiescence and stop there.
void tuckDrainActors()
{
    if (gSlotsLock is null) return;
    while (!allActorsIdle()) {}
    retireActors();
}

private bool allActorsIdle()
{
    bool allIdle = true;
    gSlotsLock.lock();
    foreach (s; gActorSlots)
    {
        s.lock.lock();
        if (s.pending || s.working) allIdle = false;
        s.lock.unlock();
    }
    gSlotsLock.unlock();
    return allIdle;
}

/// Stop every actor thread and join it, so none outlives the runtime.
/// Only after quiescence: a retiring actor leaves at its next park, and
/// one that still had work would leave it undone.
private void retireActors()
{
    gSlotsLock.lock();
    auto slots = gActorSlots.dup;
    gSlotsLock.unlock();
    foreach (s; slots)
    {
        s.lock.lock();
        s.retiring = true;
        s.cond.notify();
        s.lock.unlock();
    }
    foreach (s; slots) s.thread.join();
}

/// Emitted by each send after enqueue: wake every actor so whichever owns that
/// mailbox drains it.
///
/// THE FAST PATH IS THE POINT: a busy actor comes back round its drain loop
/// and finds the message, so it needs no wake, and this runs once per SEND.
/// Measured on the Nim twin at 3x the cost of the rest of a send when it
/// unconditionally took two locks and signalled.
/// Emitted by each send after enqueue, NAMING the actor it wrote to.
///
/// THE FAST PATH IS THE POINT — this runs once per SEND. A busy actor comes
/// back round its drain loop and finds the message itself, so the common
/// case must cost one atomic read and nothing else. `parked` lives in that
/// actor's own slot, so two senders to two different actors never touch the
/// same line.
///
/// It used to take no argument and therefore woke EVERY actor in the
/// program behind a global lock, consulting a global counter to decide
/// whether to bother: O(actors) per send, with that counter in the path of
/// every send. The send site has always known which actor it meant.
void tuckNotifySend(void* handle)
{
    if (handle is null) return;      // not registered yet: nothing is parked
    auto slot = cast(ActorSlot*) handle;
    if (!atomicLoad(slot.parked)) return;
    slot.lock.lock();
    slot.pending = true;
    slot.cond.notify();
    slot.lock.unlock();
}

/// Main blocks until a predicate over public actor state holds, driving the
/// runtime cooperatively meanwhile — main is not a coroutine, so there is
/// nothing to yield to and it must pump the queue itself.
///
/// NOTE, verified in scratchpad/actor-playground: if the predicate can never
/// hold — because a full mailbox silently dropped the messages it was
/// waiting on — this spins forever, and the Nim backend does the same. The
/// full-mailbox policy is unstated in the spec (FRICTIONS.md #9); fixing it
/// is a language decision, so this matches the reference rather than
/// inventing a third behaviour.
void runTasksUntil(bool function() pred)
{
    while (!pred())
    {
        // Nothing queued and nothing parked on the reactor: no progress
        // possible, and spinning further would never make pred() true.
        if (readyCount == 0 && gLoop.waiters.length == 0) break;
        if (readyCount > 0) stepOne();
        else runOnce(10);
    }
}

/// `scheduler::stop` — the std name for tuckStop.
void stop() { tuckStop(); }
