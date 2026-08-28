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

private __gshared Coroutine*[] readyQueue;
private __gshared bool stopped;

/// Put a coroutine on the run queue.
void schedule(Coroutine* c)
{
    if (c is null || c.state == CoroutineState.Finished) return;
    readyQueue ~= c;
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
    while (!stopped && readyQueue.length > 0)
    {
        auto c = readyQueue[0];
        readyQueue = readyQueue[1 .. $];
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
    readyQueue.length = 0;
    stopped = false;
}

/// Fire-and-forget: schedule a task, do not wait for it (spec §9.2).
void tuckSpawn(void delegate() fn) { cast(void) spawn(fn); }

/// An actor's drain loop is a daemon coroutine — queued like any other, but
/// it never finishes on its own.
void tuckStartActor(void delegate() drain) { cast(void) spawn(drain); }
