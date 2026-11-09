// The STACKLESS runtime for Odin (#216, docs/stackless-concurrency.md): the
// twin of compiler/tuck_sl.nim, which explains it. A frame fn is a frame (a
// struct whose first field is TuckFrameHdr) plus stages, `proc(env: rawptr)
// -> TuckHop`; a hop is "run this stage on this frame next" and
// tuckSlDrive loops on it. Nothing switches stacks.
//
// Frames are heap frames (new/free, so the tracking allocator sees a leaked
// one); stack and slab frames are #219. Parking a frame on an fd or a timer
// is phase 4: until then a frame that would wait stops with exit 70.
package tuckrt

import "core:fmt"
import "core:os"

TuckStageFn :: #type proc(env: rawptr) -> TuckHop

TuckHop :: struct {
	fn:  TuckStageFn,
	env: rawptr,
}

TuckFrameHdr :: struct {
	stage:  TuckStageFn,
	caller: ^TuckFrameHdr,
	next:   ^TuckFrameHdr,
}

TuckSlot :: struct($T: typeid) {
	value:  T,
	done:   bool,
	waiter: ^TuckFrameHdr,
}

@(private, thread_local)
slHead, slTail: ^TuckFrameHdr // per thread, as tuck_sl.nim says

// How many drivers are running stages on this thread: a blocking wait made
// inside a stage (tuckLendUntil) checks it, see tuckSlCannotPark.
@(thread_local) tuckSlDriving: int

tuckSlCannotPark :: proc() -> ! {
	fmt.eprintln("tuck: a stackless stage waited inside the runtime outside a helper stack (#216); build with --concurrency:stackful and report it")
	os.exit(70)
}

tuckSlReady :: proc(f: ^TuckFrameHdr) {
	f.next = nil
	if slTail == nil {slHead = f} else {slTail.next = f}
	slTail = f
}

tuckSlHasReady :: proc() -> bool {return slHead != nil}

tuckSlDrive :: proc(h: TuckHop) {
	h := h
	tuckSlDriving += 1
	for h.fn != nil {h = h.fn(h.env)}
	tuckSlDriving -= 1
}

// Run the first ready frame until it pauses or finishes; false when none.
tuckSlRunOne :: proc() -> bool {
	f := slHead
	if f == nil do return false
	slHead = f.next
	if slHead == nil do slTail = nil
	tuckSlDrive(TuckHop{f.stage, f})
	return true
}

// Run until nothing is ready: a spawned task nobody awaits still finishes.
tuckSlRunAll :: proc() {
	for tuckSlRunOne() {}
}

// The hop a finishing frame returns: its caller's next stage, or nothing.
tuckSlReturnHop :: proc(f: ^TuckFrameHdr) -> TuckHop {
	c := f.caller
	if c == nil do return TuckHop{}
	return TuckHop{c.stage, c}
}

// The task is done: its value lands in the slot and its awaiter wakes.
tuckSlComplete :: proc(s: ^TuckSlot($T), v: T) {
	s.value = v
	s.done = true
	if s.waiter != nil {
		tuckSlReady(s.waiter)
		s.waiter = nil
	}
}

// Where a frame's return value goes: its task slot, its caller's
// destination, or nowhere (a spawned task nobody awaits).
tuckSlFinish :: proc(slot: ^TuckSlot($T), dest: ^T, v: T) {
	if slot != nil {
		tuckSlComplete(slot, v)
	} else if dest != nil {
		dest^ = v
	}
}

// The [io] yield before a call in a task body: requeue, let others run.
tuckSlYield :: proc(f: ^TuckFrameHdr, next: TuckStageFn) -> TuckHop {
	f.stage = next
	tuckSlReady(f)
	return TuckHop{}
}

// Continue at `next` once the task behind `s` is done: at once if it is.
tuckSlAwait :: proc(f: ^TuckFrameHdr, s: ^TuckSlot($T), next: TuckStageFn) -> TuckHop {
	f.stage = next
	if s.done do return TuckHop{next, f}
	s.waiter = f
	return TuckHop{}
}

// A fn that is not a frame (main) awaiting a stackless task: lend the thread
// to the scheduler — frames, coroutines (the helper stacks of statements that
// wait) and the reactor — until the slot is done, as awaitResult does.
tuckSlAwaitMain :: proc(s: ^TuckSlot($T)) -> T {
	initLoop()
	for !s.done {
		if runNext() do continue
		if len(gLoop.waiters) == 0 {
			fmt.eprintln("tuck: deadlock — an awaited task can never finish (stackless)")
			os.exit(1)
		}
		runOnce(1)
	}
	return s.value
}
