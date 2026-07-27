// compiler/tuckrt/tuck_coro.odin
//
// The Odin backend's coroutine engine, mirroring compiler/tuck_coro.nim in
// the same four layers: minicoro bindings, coroutine wrapper, scheduler,
// eventloop/reactor. Both backends drive the SAME vendored C library
// (compiler/vendor/minicoro/minicoro.h), so performance characteristics
// should match — a large gap means a porting bug, not a language difference.
//
// This is materially SIMPLER than the Nim original, and deliberately so:
// Odin has no GC, so none of the `{.gcsafe.}` gymnastics or ARC
// accommodation carries over, and no stack-walker, so tuck_async.nim's
// mandatory `--stackTrace:off --lineTrace:off` has no analogue here.
//
// Linux/epoll only. The whole platform surface is six calls (epoll_create1,
// epoll_ctl, epoll_wait, timerfd_create, timerfd_settime, close) — the same
// set std/selectors gives the Nim side. kqueue/IOCP go behind this interface
// when a non-Linux target becomes real.
package tuckrt

import "core:c"
import "core:container/queue"
import "core:sys/linux"
import "base:runtime"

// ===========================================================================
// minicoro bindings  (mirrors tuck_coro.nim's libaco/minicoro layer)
// ===========================================================================

foreign import mco "minicoro.a"

McoCoro :: struct {} // opaque

McoDesc :: struct {
	func:           proc "c" (co: ^McoCoro),
	user_data:      rawptr,
	alloc_cb:       rawptr,
	dealloc_cb:     rawptr,
	allocator_data: rawptr,
	storage_size:   c.size_t,
	coro_size:      c.size_t,
	stack_size:     c.size_t,
}

MCO_SUCCESS :: 0
MCO_DEAD :: 0

@(default_calling_convention = "c")
foreign mco {
	mco_desc_init :: proc(func: proc "c" (co: ^McoCoro), stack_size: c.size_t) -> McoDesc ---
	mco_create :: proc(out_co: ^^McoCoro, desc: ^McoDesc) -> i32 ---
	mco_destroy :: proc(co: ^McoCoro) -> i32 ---
	mco_resume :: proc(co: ^McoCoro) -> i32 ---
	mco_yield :: proc(co: ^McoCoro) -> i32 ---
	mco_status :: proc(co: ^McoCoro) -> i32 ---
	mco_running :: proc() -> ^McoCoro ---
	mco_get_user_data :: proc(co: ^McoCoro) -> rawptr ---
}

// Per-coroutine stack. minicoro is built MCO_USE_VMEM_ALLOCATOR (raw mmap),
// so this is a VIRTUAL reservation: only touched pages fault in. A 1MB
// nominal stack costs the same physical RAM as 128KB for shallow Tuck
// bodies while removing the fixed-depth cap. Matches tuck_async.nim's
// TuckStackSize so both backends have the same recursion headroom.
TuckStackSize :: 1024 * 1024

// ===========================================================================
// Coroutine wrapper
// ===========================================================================

CoroutineState :: enum u8 {
	Ready, // created but never resumed
	Running,
	Suspended, // yielded, waiting to be resumed
	Finished,
}

Coroutine :: struct {
	handle:     ^McoCoro,
	entryPoint: proc(),
	state:      CoroutineState,
	ctx:        runtime.Context,
}

@(private)
activeCoroutine: ^Coroutine // running coroutine, or nil in main context

running :: proc() -> ^Coroutine {
	return activeCoroutine
}

inCoroutine :: proc() -> bool {
	return activeCoroutine != nil
}

isFinished :: proc(c: ^Coroutine) -> bool {
	return c == nil || c.state == .Finished
}

// C -> Odin bridge. `proc "c"` has no Odin context of its own, so it
// restores the one captured when the coroutine was created.
@(private)
trampoline :: proc "c" (mc: ^McoCoro) {
	co := cast(^Coroutine)mco_get_user_data(mc)
	context = co.ctx
	if co.entryPoint != nil {
		co.entryPoint()
	}
	co.state = .Finished
}

newCoroutine :: proc(fn: proc(), stackSize: int = TuckStackSize) -> ^Coroutine {
	co := new(Coroutine)
	co.entryPoint = fn
	co.state = .Ready
	co.ctx = context
	// mco_desc_init fills coro_size/alignment/allocator internals that
	// mco_create validates; a hand-zeroed desc fails with INVALID_ARGUMENTS.
	desc := mco_desc_init(trampoline, c.size_t(stackSize))
	desc.user_data = rawptr(co)
	if mco_create(&co.handle, &desc) != MCO_SUCCESS {
		panic("tuck: failed to create coroutine")
	}
	return co
}

resume :: proc(c: ^Coroutine) {
	if c == nil || c.state == .Finished do return
	prev := activeCoroutine
	activeCoroutine = c
	c.state = .Running
	mco_resume(c.handle)
	activeCoroutine = prev
	if mco_status(c.handle) == MCO_DEAD {
		c.state = .Finished
	} else if c.state == .Running {
		c.state = .Suspended
	}
}

coroYield :: proc() {
	c := activeCoroutine
	if c == nil {
		panic("tuck: cannot yield outside a coroutine")
	}
	c.state = .Suspended
	mco_yield(mco_running())
	c.state = .Running
}

destroyCoroutine :: proc(c: ^Coroutine) {
	if c == nil || c.handle == nil do return
	mco_destroy(c.handle)
	c.handle = nil
	free(c)
}

// ===========================================================================
// Scheduler  (round-robin, mirrors arsenal/scheduler.nim)
// ===========================================================================

@(private)
Scheduler :: struct {
	readyQueue:  queue.Queue(^Coroutine),
	currentCoro: ^Coroutine,
	inited:      bool,
}

@(private)
globalScheduler: Scheduler

@(private)
initScheduler :: proc() {
	if !globalScheduler.inited {
		queue.init(&globalScheduler.readyQueue)
		globalScheduler.inited = true
	}
}

ready :: proc(coro: ^Coroutine) {
	if coro == nil || isFinished(coro) do return
	initScheduler()
	queue.push_back(&globalScheduler.readyQueue, coro)
}

schedule :: proc(coro: ^Coroutine) {
	ready(coro)
}

spawn :: proc(fn: proc()) -> ^Coroutine {
	c := newCoroutine(fn)
	ready(c)
	return c
}

hasPending :: proc() -> bool {
	initScheduler()
	return queue.len(globalScheduler.readyQueue) > 0
}

currentCoroutine :: proc() -> ^Coroutine {
	return globalScheduler.currentCoro
}

runNext :: proc() -> bool {
	initScheduler()
	if queue.len(globalScheduler.readyQueue) == 0 do return false

	coro := queue.pop_front(&globalScheduler.readyQueue)
	if isFinished(coro) {
		return queue.len(globalScheduler.readyQueue) > 0
	}

	globalScheduler.currentCoro = coro
	resume(coro)
	globalScheduler.currentCoro = nil

	// A coroutine parked on I/O or a timer is re-queued by the reactor when
	// its event fires. A plain coroYield() has no waker at all, so it is
	// re-queued here — otherwise cooperative yielding would silently drop it.
	if !isFinished(coro) && !coro_parked(coro) {
		queue.push_back(&globalScheduler.readyQueue, coro)
	}
	return true
}

runAll :: proc() {
	for runNext() {}
}

// ===========================================================================
// Event loop / reactor  (epoll + timerfd; mirrors arsenal/io/eventloop.nim)
// ===========================================================================

@(private)
IoWaiter :: struct {
	coro:    ^Coroutine,
	isTimer: bool,
}

@(private)
EventLoop :: struct {
	epfd:    linux.Fd,
	waiters: map[linux.Fd]IoWaiter,
	// Coroutines parked on this loop; runNext must NOT re-queue them.
	parked:  map[rawptr]bool,
	stopped: bool,
	inited:  bool,
}

@(private)
gLoop: EventLoop

@(private)
coro_parked :: proc(c: ^Coroutine) -> bool {
	return gLoop.inited && (rawptr(c) in gLoop.parked)
}

@(private)
initLoop :: proc() {
	if gLoop.inited do return
	fd, err := linux.epoll_create1({})
	if err != nil {
		panic("tuck: epoll_create1 failed")
	}
	gLoop.epfd = fd
	gLoop.waiters = make(map[linux.Fd]IoWaiter)
	gLoop.parked = make(map[rawptr]bool)
	gLoop.inited = true
}

@(private)
parkCurrent :: proc(fd: linux.Fd, isTimer: bool) {
	c := activeCoroutine
	if c == nil {
		panic("tuck: cannot await outside a coroutine")
	}
	gLoop.waiters[fd] = IoWaiter{coro = c, isTimer = isTimer}
	gLoop.parked[rawptr(c)] = true
	coroYield()
	delete_key(&gLoop.parked, rawptr(c))
}

@(private)
armTimer :: proc(ms: int) -> (linux.Fd, bool) {
	tfd, terr := linux.timerfd_create(.MONOTONIC, {})
	if terr != nil do return 0, false
	spec := linux.ITimer_Spec {
		value = {
			time_sec = uint(ms / 1000),
			time_nsec = uint((ms % 1000) * 1_000_000),
		},
	}
	if linux.timerfd_settime(tfd, {}, &spec, nil) != nil {
		linux.close(tfd)
		return 0, false
	}
	ev := linux.EPoll_Event {
		events = {.IN},
		data = {fd = tfd},
	}
	if linux.epoll_ctl(gLoop.epfd, .ADD, tfd, &ev) != nil {
		linux.close(tfd)
		return 0, false
	}
	return tfd, true
}

@(private)
watchFd :: proc(fd: linux.Fd, write: bool) -> bool {
	ev := linux.EPoll_Event {
		data = {fd = fd},
	}
	ev.events = write ? {.OUT} : {.IN}
	return linux.epoll_ctl(gLoop.epfd, .ADD, fd, &ev) == nil
}

@(private)
unwatch :: proc(fd: linux.Fd, isTimer: bool) {
	linux.epoll_ctl(gLoop.epfd, .DEL, fd, nil)
	delete_key(&gLoop.waiters, fd)
	if isTimer do linux.close(fd)
}

// Suspend until `fd` is readable.
tuckAwaitRead :: proc(fd: int) {
	initLoop()
	if !watchFd(linux.Fd(fd), false) do return
	parkCurrent(linux.Fd(fd), false)
	unwatch(linux.Fd(fd), false)
}

tuckAwaitWrite :: proc(fd: int) {
	initLoop()
	if !watchFd(linux.Fd(fd), true) do return
	parkCurrent(linux.Fd(fd), true)
	unwatch(linux.Fd(fd), false)
}

// Cooperative sleep: suspend this coroutine for `ms`, driven by the reactor.
tuckSleep :: proc(ms: int) {
	initLoop()
	tfd, okArm := armTimer(ms)
	if !okArm do return
	parkCurrent(tfd, true)
	unwatch(tfd, true)
}

// Suspend until `fd` is readable OR timeoutMs elapses.
// Returns true if readable, false if it timed out — the operation-timeout
// primitive (spec §9.3). Whichever side loses the race is torn down here;
// leaving it registered would later wake a coroutine that has moved on.
tuckAwaitReadOrTimeout :: proc(fd: int, timeoutMs: int) -> bool {
	initLoop()
	rfd := linux.Fd(fd)
	if !watchFd(rfd, false) do return false
	tfd, okArm := armTimer(timeoutMs)
	if !okArm {
		unwatch(rfd, false)
		return false
	}

	c := activeCoroutine
	if c == nil {
		panic("tuck: cannot await outside a coroutine")
	}
	gLoop.waiters[rfd] = IoWaiter{coro = c, isTimer = false}
	gLoop.waiters[tfd] = IoWaiter{coro = c, isTimer = true}
	gLoop.parked[rawptr(c)] = true
	coroYield()
	delete_key(&gLoop.parked, rawptr(c))

	// Exactly one side fired and was removed by runOnce; whichever is still
	// registered lost the race.
	readable := !(rfd in gLoop.waiters)
	unwatch(rfd, false)
	unwatch(tfd, true)
	return readable
}

// Process one batch of events. Returns true if anything was resumed.
runOnce :: proc(timeoutMs: int = 100) -> bool {
	initLoop()
	events: [64]linux.EPoll_Event
	n, err := linux.epoll_wait(gLoop.epfd, &events[0], 64, i32(timeoutMs))
	if err != nil || n <= 0 do return false

	// A read racing a timeout can land BOTH sides in one batch, so a
	// coroutine already resumed in this pass must not be queued twice.
	resumed := make(map[rawptr]bool, context.temp_allocator)
	for i in 0 ..< int(n) {
		fd := linux.Fd(events[i].data.fd)
		w, found := gLoop.waiters[fd]
		if !found do continue
		delete_key(&gLoop.waiters, fd)
		if rawptr(w.coro) not_in resumed {
			resumed[rawptr(w.coro)] = true
			delete_key(&gLoop.parked, rawptr(w.coro))
			ready(w.coro)
		}
	}
	return true
}

// Run until no coroutine is ready and nothing is waiting on the reactor.
tuckRun :: proc() {
	initLoop()
	gLoop.stopped = false
	for !gLoop.stopped {
		for hasPending() {
			if !runNext() do break
		}
		if len(gLoop.waiters) == 0 && !hasPending() do break
		runOnce(100)
	}
}

tuckStop :: proc() {
	gLoop.stopped = true
}

// ===========================================================================
// Tuck-facing API  (the 10 entry points codegen targets — tuck_async.nim)
// ===========================================================================

tuckAsyncInit :: proc() {
	initScheduler()
	initLoop()
}

tuckSpawn :: proc(fn: proc()) {
	schedule(newCoroutine(fn, TuckStackSize))
}

tuckYield :: proc() {
	coroYield()
}

// Actors are daemon coroutines: they park on their mailbox and are woken by
// a send. gActors keeps them alive for the lifetime of the program.
@(private)
gActors: [dynamic]^Coroutine

tuckStartActor :: proc(drain: proc()) {
	c := newCoroutine(drain, TuckStackSize)
	append(&gActors, c)
	schedule(c)
}

// A send makes every parked actor runnable again; the drain loop re-parks
// any actor whose mailbox turned out to be empty.
tuckNotifySend :: proc() {
	for a in gActors {
		if !isFinished(a) do ready(a)
	}
}

// Suspend until `pred` holds, letting other coroutines run in between.
// Named to match std/scheduler.tuck's `waitUntil` extern, which the module
// forwarder emits as `rt.waitUntil`.
waitUntil :: proc(pred: proc() -> bool) {
	for !pred() {
		if inCoroutine() {
			coroYield()
		} else {
			if !runNext() do runOnce(10)
		}
	}
}
