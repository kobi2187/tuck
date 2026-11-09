/// The STACKLESS runtime for D (#216, docs/stackless-concurrency.md): the
/// twin of compiler/tuck_sl.nim, which explains it. A frame fn is a frame (a
/// struct whose first field is TuckFrameHdr) plus stages,
/// `TuckHop function(void* env)`; a hop is "run this stage on this frame
/// next" and tuckSlDrive loops on it. Nothing switches stacks.
///
/// Frames are heap frames (malloc/free, outside the GC); stack and slab
/// frames are #219. Parking a frame on an fd or a timer is phase 4: until
/// then a frame that would wait stops with exit 70.
module tuck_sl;

import core.stdc.stdlib : exit;
import std.stdio : stderr;

alias TuckStageFn = TuckHop function(void* env);

struct TuckHop
{
    TuckStageFn fn;
    void* env;
}

struct TuckFrameHdr
{
    TuckStageFn stage;
    TuckFrameHdr* caller;
    TuckFrameHdr* next;
}

struct TuckSlot(T)
{
    T value;
    bool done;
    TuckFrameHdr* waiter;
}

private TuckFrameHdr* slHead, slTail;   // thread-local (D's default), as tuck_sl.nim says

/// How many drivers are running stages on this thread: a blocking wait made
/// inside a stage (tuckLendUntil) checks it, see tuckSlCannotPark.
int tuckSlDriving;

void tuckSlCannotPark()
{
    stderr.writeln("tuck: a stackless stage waited inside the runtime outside a helper stack (#216); build with --concurrency:stackful and report it");
    stderr.flush();
    exit(70);
}

void tuckSlReady(TuckFrameHdr* f)
{
    f.next = null;
    if (slTail is null) slHead = f; else slTail.next = f;
    slTail = f;
}

bool tuckSlHasReady() { return slHead !is null; }

void tuckSlDrive(TuckHop h)
{
    ++tuckSlDriving;
    while (h.fn !is null) h = h.fn(h.env);
    --tuckSlDriving;
}

/// Run the first ready frame until it pauses or finishes; false when none.
bool tuckSlRunOne()
{
    auto f = slHead;
    if (f is null) return false;
    slHead = f.next;
    if (slHead is null) slTail = null;
    tuckSlDrive(TuckHop(f.stage, f));
    return true;
}

/// Run until nothing is ready: a spawned task nobody awaits still finishes.
void tuckSlRunAll() { while (tuckSlRunOne()) {} }

/// The hop a finishing frame returns: its caller's next stage, or nothing.
TuckHop tuckSlReturnHop(TuckFrameHdr* f)
{
    auto c = f.caller;
    if (c is null) return TuckHop.init;
    return TuckHop(c.stage, c);
}

/// The task is done: its value lands in the slot and its awaiter wakes.
void tuckSlComplete(T)(TuckSlot!T* s, T v)
{
    s.value = v;
    s.done = true;
    if (s.waiter !is null)
    {
        tuckSlReady(s.waiter);
        s.waiter = null;
    }
}

/// Where a frame's return value goes: its task slot, its caller's
/// destination, or nowhere (a spawned task nobody awaits).
void tuckSlFinish(T)(TuckSlot!T* slot, T* dest, T v)
{
    if (slot !is null) tuckSlComplete(slot, v);
    else if (dest !is null) *dest = v;
}

/// The [io] yield before a call in a task body: requeue, let others run.
TuckHop tuckSlYield(TuckFrameHdr* f, TuckStageFn next)
{
    f.stage = next;
    tuckSlReady(f);
    return TuckHop.init;
}

/// Continue at `next` once the task behind `s` is done: at once if it is.
TuckHop tuckSlAwait(T)(TuckFrameHdr* f, TuckSlot!T* s, TuckStageFn next)
{
    f.stage = next;
    if (s.done) return TuckHop(next, f);
    s.waiter = f;
    return TuckHop.init;
}
