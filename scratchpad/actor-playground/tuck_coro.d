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
// Linux only, like the Odin runtime. The reactor (epoll/timerfd) lands with
// the awaiting primitives; this file is the scheduler foundation those sit
// on.
module tuck_coro;

import core.stdc.stdlib : abort;
import std.stdio : stderr;

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

private __gshared Coroutine* activeCoroutine;  /// null in the main context

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
private __gshared Coroutine** readyQueue;
private __gshared size_t readyHead;   /// next to run
private __gshared size_t readyTail;   /// next free slot
private __gshared size_t readyCap;
private __gshared bool stopped;

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

/// Drive the queue until it drains. Called after `main` so spawned tasks get
/// to finish (mirrors tuck.nim's entry for the Nim backend).
void tuckRun()
{
    while (!stopped && readyCount > 0)
    {
        auto c = takeReady();
        resume(c);
        // A coroutine that yielded re-queued itself in tuckYield; one that
        // parked on an fd will be re-queued by the reactor when it lands.
        if (c.state == CoroutineState.Finished)
            destroyCoroutine(c);
    }
}

void tuckStop() { stopped = true; }

void tuckAsyncInit()
{
    readyHead = 0;
    readyTail = 0;
    stopped = false;
}

/// Fire-and-forget: schedule a task, do not wait for it (spec §9.2).
void tuckSpawn(void delegate() fn) { cast(void) spawn(fn); }

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
    if (inCoroutine())
    {
        while (!slot.done) tuckYield();
    }
    else
    {
        while (!slot.done && readyCount > 0)
        {
            auto c = takeReady();
            resume(c);
            if (c.state == CoroutineState.Finished) destroyCoroutine(c);
        }
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

private __gshared Coroutine*[] actorCoros;

/// Register and start a declared actor as a looping coroutine (emitted once
/// per actor). The loop drains, then yields when idle; a send reschedules it.
void tuckStartActor(DrainProc drain)
{
    auto co = newCoroutine({
        while (true)
        {
            if (!drain()) suspend();   // idle — hand control back
        }
    });
    actorCoros ~= co;
    schedule(co);
}

/// Emitted by each send after enqueue: reschedule idle actors so they drain
/// on the next scheduler pass.
void tuckNotifySend()
{
    foreach (co; actorCoros)
        if (!isFinished(co)) schedule(co);
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
void waitUntil(bool function() pred)
{
    while (!pred())
    {
        if (readyCount == 0) break;   // nothing left to run: no progress possible
        auto c = takeReady();
        resume(c);
        if (c.state == CoroutineState.Finished) destroyCoroutine(c);
    }
}

/// `scheduler::stop` — the std name for tuckStop.
void stop() { tuckStop(); }
