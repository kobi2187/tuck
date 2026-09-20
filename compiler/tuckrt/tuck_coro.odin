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
import "core:thread"
import "core:sync"
import "base:intrinsics"
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

// PER THREAD, not per program. Each actor runs on its own OS thread with its
// own scheduler and reactor (spec 9.1), so the "currently running coroutine"
// is a property of the THREAD. Nim's twin has been a {.threadvar.} all along;
// these were plain globals, and sharing them across actor threads would have
// each one resuming another's coroutine.
@(private)
@(thread_local)
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

@(private)
parkSuspend :: proc() {
	c := activeCoroutine
	if c == nil {
		panic("tuck: cannot yield outside a coroutine")
	}
	c.state = .Suspended
	mco_yield(mco_running())
	c.state = .Running
}

// Cooperative yield: re-schedule THIS coroutine, then suspend. Every plain-
// yield call site (actor drains, tuckYield, waitUntil, awaitResult) goes
// through this, so a resume always re-queues at exactly the yield point that
// asked for it — never a second-guess made by runNext after the fact by
// checking whether this suspension happened to be an I/O park. An I/O park
// (parkCurrent, tuckAwaitReadOrTimeout) must NOT self-requeue — the reactor
// re-queues those once the fd/timer actually fires — so those call
// parkSuspend directly instead of this.
coroYield :: proc() {
	c := activeCoroutine
	if c == nil {
		panic("tuck: cannot yield outside a coroutine")
	}
	ready(c)
	parkSuspend()
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
@(thread_local)
globalScheduler: Scheduler   // per thread — see activeCoroutine above

@(private)
initScheduler :: proc() {
	if !globalScheduler.inited {
		queue.init(&globalScheduler.readyQueue)
		globalScheduler.inited = true
	}
}

// `ready` is PRIVATE: it is a plausible Tuck function name — 27-actor-select
// declares `fn ready` — and nothing outside this package needs it. The
// runtime lives in its own package so a clash is not an error either way,
// but keeping the surface small stops emitted code binding the wrong one.
@(private)
ready :: proc(coro: ^Coroutine) {
	if coro == nil || isFinished(coro) do return
	initScheduler()
	queue.push_back(&globalScheduler.readyQueue, coro)
}

schedule :: proc(coro: ^Coroutine) {
	ready(coro)
}

@(private)
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
		// Defensive: `ready` already refuses to queue a finished coroutine,
		// so this should not happen in practice. Destroy rather than leak
		// if it ever does.
		destroyCoroutine(coro)
		return queue.len(globalScheduler.readyQueue) > 0
	}

	globalScheduler.currentCoro = coro
	resume(coro)
	globalScheduler.currentCoro = nil

	// No re-queue decision made here: every suspend point already made it.
	// coroYield() re-schedules itself before suspending; parkCurrent and
	// tuckAwaitReadOrTimeout deliberately do not — the reactor re-queues
	// those once their fd/timer fires. A coroutine that finished is reaped
	// here, the one place that sees every coroutine exactly once per run.
	if isFinished(coro) {
		destroyCoroutine(coro)
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
	stopped: bool,
	inited:  bool,
}

@(private)
@(thread_local)
gLoop: EventLoop             // per thread — see activeCoroutine above

@(private)
initLoop :: proc() {
	if gLoop.inited do return
	fd, err := linux.epoll_create1({})
	if err != nil {
		panic("tuck: epoll_create1 failed")
	}
	gLoop.epfd = fd
	gLoop.waiters = make(map[linux.Fd]IoWaiter)
	gLoop.inited = true
}

@(private)
parkCurrent :: proc(fd: linux.Fd, isTimer: bool) {
	c := activeCoroutine
	if c == nil {
		panic("tuck: cannot await outside a coroutine")
	}
	gLoop.waiters[fd] = IoWaiter{coro = c, isTimer = isTimer}
	parkSuspend()
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
	parkSuspend()

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
		// Checked AFTER the drain so a coroutine that called stop() in this
		// pass is honoured immediately, rather than after another 100ms parked
		// in epoll_wait. Mirrors the Nim run().
		if gLoop.stopped do break
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

// ---------------------------------------------------------------------------
// The offload seam — mirrors tuck_async.nim's tuckSubmitBlocking.
//
// A blocking operation cannot be made to yield: a regular file is always
// "ready" to epoll, so the reactor is structurally incapable of awaiting one.
// The work runs on a worker thread and signals completion by writing one byte
// to a pipe the reactor already watches, which resumes the parked coroutine.
//
// MEASURED (thoughts/async-endgame-measurements.md): one worker serializes, so
// N concurrent blocking calls cost N*work. A pool of K caps at exactly K and
// then goes linear again — it buys a constant, not asynchrony. Anything with
// real fd readiness (sockets, pipes, tty, timers) belongs on the reactor
// instead and should never reach this. Files, path metadata and DNS are the
// worker's permanent job.
//
// The contract is the same as the Nim side, and simpler to honour here because
// Odin has no GC: the worker touches only the request's own pointers, one
// syscall, and the completion write. It never schedules and never allocates.

BlockingFn :: proc(arg: rawptr)

@(private)
BlockingReq :: struct {
	fn:     BlockingFn,
	arg:    rawptr,
	doneFd: linux.Fd,
}

@(private)
gBlockingStarted: bool

@(private)
gReqPipe: [2]linux.Fd

@(private)
blockingWorker :: proc(t: ^thread.Thread) {
	for {
		req: BlockingReq
		n, rerr := linux.read(gReqPipe[0], ([^]u8)(&req)[:size_of(BlockingReq)])
		if rerr != nil || n != size_of(BlockingReq) do break
		req.fn(req.arg)
		b: [1]u8 = {1}
		_, _ = linux.write(req.doneFd, b[:])
		linux.close(req.doneFd)
	}
}

@(private)
ensureBlockingThread :: proc() {
	// Started on first use: a program that never blocks never pays for a
	// thread. One worker, process lifetime, never joined — it parks in read()
	// on the request pipe when idle.
	if gBlockingStarted do return
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {}) != nil do return
	gReqPipe = fds
	t := thread.create(blockingWorker)
	if t == nil do return
	thread.start(t)
	gBlockingStarted = true
}

// Run `fn(arg)` off the scheduler thread and SUSPEND this coroutine until it
// finishes. The scheduler, the reactor, every actor and every timer keep
// running meanwhile.
//
// Called outside a coroutine this runs inline: there is nothing to yield to,
// and parking would deadlock.
tuckSubmitBlocking :: proc(fn: BlockingFn, arg: rawptr) {
	if activeCoroutine == nil {
		fn(arg)
		return
	}
	initLoop()
	ensureBlockingThread()
	if !gBlockingStarted {
		fn(arg)   // no worker: better inline than not at all
		return
	}
	done: [2]linux.Fd
	if linux.pipe2(&done, {}) != nil {
		fn(arg)
		return
	}
	req := BlockingReq{fn = fn, arg = arg, doneFd = done[1]}
	buf := ([^]u8)(&req)[:size_of(BlockingReq)]
	_, _ = linux.write(gReqPipe[1], buf)
	tuckAwaitRead(int(done[0]))   // the reactor resumes us when the byte lands
	b: [1]u8
	_, _ = linux.read(done[0], b[:])
	linux.close(done[0])
}

tuckSpawn :: proc(fn: proc()) {
	schedule(newCoroutine(fn, TuckStackSize))
}

tuckYield :: proc() {
	coroYield()
}

// ONE OS THREAD PER ACTOR (ruled 2026-09-18) — the Nim twin carries the full
// reasoning. An actor is a daemon, and a daemon that only runs when main
// happens to yield is not one: under the previous design a program with no
// `waitUntil` never delivered a message at all (#8).
//
// The drain now returns a bool ("did I work") and the RUNTIME owns the loop,
// matching Nim and D. Odin was the one backend where the emitted drain owned
// its own `for` and decided when to park, which is what made #28 possible.
DrainProc :: proc() -> bool

@(private)
Waiter :: struct {
	pred:      proc() -> bool,
	doneFd:    linux.Fd,     // one byte written when the predicate holds
	satisfied: bool,
}

@(private)
ActorSlot :: struct {
	drain:   DrainProc,
	lock:    sync.Mutex,
	cond:    sync.Cond,
	pending: bool,
	working: bool,
	parked:  bool,   // asleep on `cond`. Read WITHOUT the lock: it is the
	                 // whole fast path of a send, so it must be per-actor
	                 // rather than a global anything.
	waiters: [dynamic]^Waiter,
}

// How far an idle actor re-checks its mailbox before parking. Adaptive,
// because a fixed budget is two bets on two workloads and cannot win both:
// spinning always pays for a saturated actor and never for an idle one.
// Measured on the Nim runtime, 8 light actors: a fixed 2000-iteration spin
// burned 1.38 cores against 0.37 for parking at once.
@(private)
ActorSpinMax :: 4096
@(private)
ActorSpinMin :: 16

@(private)
gActorSlots: [dynamic]^ActorSlot   // SHARED: tuckDrainActors has to reach
@(private)                         // every actor at exit
gSlotsLock: sync.Mutex

@(private)
@(thread_local)
gMySlot: ^ActorSlot                // the slot THIS thread serves

@(private)
checkWaiters :: proc(slot: ^ActorSlot) {
	// Evaluate every registered predicate and wake whoever is satisfied.
	// ALWAYS on the actor's own thread, where the state is settled.
	// The length check first is the "free when unused" property.
	if len(slot.waiters) == 0 do return
	woken: [dynamic]^Waiter
	defer delete(woken)
	sync.lock(&slot.lock)
	kept: [dynamic]^Waiter
	for w in slot.waiters {
		if w.satisfied do continue
		if w.pred() {
			w.satisfied = true
			append(&woken, w)
		} else {
			append(&kept, w)
		}
	}
	delete(slot.waiters)
	slot.waiters = kept
	sync.unlock(&slot.lock)
	// Outside the lock: the waiter wakes at once and must not contend for a
	// lock it is about to stop caring about.
	for w in woken {
		b: byte = 1
		linux.write(w.doneFd, ([^]byte)(&b)[:1])
		linux.close(w.doneFd)
	}
}

// Emitted in the drain loop after each handled message, so a predicate sees the
// EXACT moment it becomes true rather than once per batch.
tuckCheckWaiters :: proc() {
	if gMySlot != nil do checkWaiters(gMySlot)
}

@(private)
actorMain :: proc(t: ^thread.Thread) {
	slot := (^ActorSlot)(t.data)
	tuckAsyncInit()          // this thread's own scheduler and reactor
	gMySlot = slot
	spinBudget := ActorSpinMin   // each actor earns its own
	for {
		if slot.drain() do continue
		checkWaiters(slot)
		// Spin for as long as spinning has been paying. A producer still
		// running hands over more work within nanoseconds, while a park costs
		// a futex sleep here and a wake at the next sender. `working` stays
		// true throughout: a spinning actor has not given up, and
		// tuckDrainActors must not read it as quiescent.
		gotWork := false
		for _ in 0 ..< spinBudget {
			if slot.drain() {
				gotWork = true
				break
			}
		}
		if gotWork {
			spinBudget = min(spinBudget * 2, ActorSpinMax)
			continue
		}
		spinBudget = max(spinBudget / 2, ActorSpinMin)
		// ARM, THEN LOOK AGAIN (EV-7). Publishing `parked` and then sleeping
		// is not enough: a sender that enqueued just before that store reads
		// `parked` as false, returns without signalling, and its message sits
		// in a mailbox nobody will be woken for. The recheck closes it from
		// THIS side alone, leaving the sender's fast path untouched — the
		// drain takes the mailbox spinlock, whose exchange is a full barrier,
		// so the arming store is visible before any send that could follow.
		sync.lock(&slot.lock)
		slot.working = false
		mustPark := !slot.pending
		if mustPark do intrinsics.atomic_store(&slot.parked, true)
		sync.unlock(&slot.lock)
		if mustPark && slot.drain() {
			intrinsics.atomic_store(&slot.parked, false)
			sync.lock(&slot.lock)
			slot.working = true
			sync.unlock(&slot.lock)
			continue
		}
		sync.lock(&slot.lock)
		for !slot.pending {
			sync.cond_wait(&slot.cond, &slot.lock)
		}
		intrinsics.atomic_store(&slot.parked, false)
		slot.pending = false
		slot.working = true
		sync.unlock(&slot.lock)
	}
}

tuckStartActor :: proc(drain: DrainProc) -> rawptr {
	// Detached by design: actors are daemons with no termination condition, so
	// there is nothing to join. The process exits and they go with it.
	slot := new(ActorSlot)
	slot.drain = drain
	slot.pending = true      // drain once before the first wait: a send may
	slot.working = true      // already be queued by the time we get here
	sync.lock(&gSlotsLock)
	append(&gActorSlots, slot)
	sync.unlock(&gSlotsLock)
	t := thread.create(actorMain)
	t.data = rawptr(slot)
	thread.start(t)
	return rawptr(slot)
}

tuckWaitOn :: proc(handle: rawptr, pred: proc() -> bool) {
	// `Actor.waitUntil {pred: :p}` — register with THAT actor and block.
	// The predicate is evaluated on the actor's thread, so the answer is
	// neither racy nor stale.
	if handle == nil do return
	slot := (^ActorSlot)(handle)
	w := new(Waiter)
	w.pred = pred
	fds: [2]linux.Fd
	// NONBLOCK at creation rather than fcntl after: main polls this fd while
	// still driving its own tasks (see below), so a blocking read would be the
	// deadlock this branch exists to avoid.
	linux.pipe2(&fds, {.NONBLOCK})
	w.doneFd = fds[1]
	sync.lock(&slot.lock)
	append(&slot.waiters, w)
	slot.pending = true      // evaluate ONCE IMMEDIATELY: the condition may
	sync.cond_signal(&slot.cond)   // already hold
	sync.unlock(&slot.lock)
	// From a TASK: park through the reactor — blocking the thread would freeze
	// every other task on it.
	//
	// From MAIN: keep driving main's own tasks while waiting. A plain blocking
	// read DEADLOCKS whenever the condition depends on a task, because main's
	// thread is the only thing that runs tasks and blocking it stops the very
	// work that would make the predicate true.
	b: byte = 0
	if inCoroutine() {
		tuckAwaitRead(int(fds[0]))
		linux.read(fds[0], ([^]byte)(&b)[:1])
	} else {
		for {
			n, _ := linux.read(fds[0], ([^]byte)(&b)[:1])
			if n == 1 do break
			if hasPending() { runNext() } else { runOnce(1) }
		}
	}
	linux.close(fds[0])
}

tuckDrainActors :: proc() {
	// Wait for every actor to empty its mailbox. Emitted at the END of main.
	// Without it `send` races `quit`: the message is in the ring and the
	// detached thread may never have been scheduled.
	for {
		allIdle := true
		sync.lock(&gSlotsLock)
		for s in gActorSlots {
			sync.lock(&s.lock)
			if s.pending || s.working do allIdle = false
			sync.unlock(&s.lock)
		}
		sync.unlock(&gSlotsLock)
		if allIdle do return
	}
}

// Emitted by each send after enqueue, NAMING the actor it wrote to.
//
// It was not emitted AT ALL until 2026-09-20: genSender enqueued and stopped,
// so a send to an actor parked on its condvar was a lost wakeup and the
// message sat in the ring forever (KNOWN-BUGS-EVENTS.md EV-5).
//
// THE FAST PATH IS THE POINT — this runs once per SEND. A busy actor comes
// back round its drain loop and finds the message itself, so the common case
// must cost one atomic read and nothing else. `parked` lives in that actor's
// own slot, so two senders to two different actors never touch the same line.
tuckNotifySend :: proc(handle: rawptr) {
	if handle == nil do return   // not registered yet: nothing is parked
	slot := (^ActorSlot)(handle)
	if !intrinsics.atomic_load(&slot.parked) do return
	sync.lock(&slot.lock)
	slot.pending = true
	sync.cond_signal(&slot.cond)
	sync.unlock(&slot.lock)
}

// Run THIS thread's coroutines until `pred` holds. Named to match
// std/scheduler.tuck's `runTasksUntil` extern, which the module forwarder
// emits as `rt.runTasksUntil`.
//
// It DRIVES rather than waits — see the Nim twin for why the old `waitUntil`
// name became misleading once actors got their own threads.
runTasksUntil :: proc(pred: proc() -> bool) {
	for !pred() {
		if inCoroutine() {
			coroYield()
		} else {
			if !runNext() do runOnce(10)
		}
	}
}

// std/scheduler.tuck's `stop` extern. Ends the loop even while coroutines are
// still parked on fds — tuckRun otherwise returns only when NOTHING is
// waiting, so one coroutine parked on an fd that never becomes readable (a
// server's accept loop) would keep the program alive forever.
stop :: proc() {
	tuckStop()
}

// --- a demo async source ----------------------------------------------------
// A REAL non-blocking source: a pipe whose write end is fed by a writer
// coroutine after `ms` (a reactor-driven sleep, no OS thread — that would
// fight the coroutine model). So the read fd genuinely becomes readable at
// `ms`, and a task racing `read fd` against `timeout N` sees the true
// winner: data if ms < N (read arm), timeout if ms > N. Mirrors
// tuck_async.nim's openSource exactly — the runtimes must agree on what
// "async" means, or a program's behaviour would depend on which backend
// built it.
//
// Odin, unlike Nim, has NO implicit closures — a `proc()` literal cannot
// read an outer local (verified: `x := 42; f := proc() { fmt.println(x) }`
// fails "Undeclared name: x"). `context.user_ptr` is Odin's own mechanism
// for exactly this, and it already threads correctly through THIS runtime's
// coroutine boundary: newCoroutine snapshots `context` into `co.ctx` at
// spawn time, and the C trampoline restores it before calling entryPoint —
// so setting user_ptr right before tuckSpawn hands the writer coroutine
// its data with no change to the shared coroutine API.
OpenSourceEnv :: struct {
	ms: int,
	wr: linux.Fd,
}

openSourceWriter :: proc() {
	env := (^OpenSourceEnv)(context.user_ptr)
	tuckSleep(env.ms)
	b: [1]u8 = {1}
	_, _ = linux.write(env.wr, b[:])
	linux.close(env.wr)
	free(env)
}

// A plain record return, `{fd: int}` — the forwarder codegen emits
// (Odin's genRtForwarder/forwardRecord) reads a named field off whatever
// this returns, so a bare int (or Odin's named-return sugar, which is
// still just int underneath) does not satisfy it. NetFd is the SAME
// {fd: int} shape std/net's listen/accept already return; reused rather
// than declaring a second identical struct.
openSource :: proc(ms: int) -> NetFd {
	pipes: [2]linux.Fd
	if linux.pipe2(&pipes, {}) != .NONE do return NetFd{fd = -1}
	env := new(OpenSourceEnv)
	env.ms = ms
	env.wr = pipes[1]
	saved := context.user_ptr
	context.user_ptr = env
	tuckSpawn(openSourceWriter)
	context.user_ptr = saved
	return NetFd{fd = int(pipes[0])}
}

// --- task results -----------------------------------------------------------
// A task returns a value: `let r = {args} fetch` schedules fetch with a
// result slot, and reading `r` awaits that slot. TuckAsyncResult/
// newAsyncResult/awaitResult mirror tuck_async.nim's trio, generic over T
// the same way Odin's parametric polymorphism allows.
//
// There is no spawnResult here, unlike Nim. Nim's version takes a `body:
// proc(): T {.closure.}` and lets the closure capture the task's real
// arguments for free. Odin has no closures (verified: a proc literal
// cannot read an outer local) — so args must travel through
// context.user_ptr instead, THE SAME SLOT spawnResult itself would need for
// `slot` and `body`. Two independent marshaling layers sharing one slot
// collide: an early version had spawnResult stash {slot, body} in
// context.user_ptr, tuckSpawn a wrapper that reads them back and calls
// body() — but body (the CALLER's own generated wrapper) ALSO reads
// context.user_ptr, expecting ITS OWN args struct, and instead got
// spawnResult's. It segfaulted inside the coroutine, on `e.slot.done =
// true`, in exactly the way "compiles and typechecks" cannot catch —
// found only by running it (two independent probes, one per race
// outcome, both traced with gdb to the exact write).
//
// The fix is one env, one wrapper, one context.user_ptr layer — matching
// openSource's already-proven shape exactly. There is nothing generic left
// for a runtime proc to do: the caller builds a per-call-site env carrying
// both its own arguments AND the result slot, and a per-call-site wrapper
// (which codegen generates, one per distinct task signature) reads it,
// calls the real task, and writes the slot itself. tuckSpawn needs no
// closure-shaped counterpart because the wrapper is already nullary.
TuckAsyncResult :: struct($T: typeid) {
	value: T,
	done:  bool,
}

newAsyncResult :: proc($T: typeid) -> ^TuckAsyncResult(T) {
	return new(TuckAsyncResult(T))
}

awaitResult :: proc(slot: ^TuckAsyncResult($T)) -> T {
	for !slot.done {
		if inCoroutine() {
			coroYield()
		} else {
			if !runNext() do runOnce(1)
		}
	}
	return slot.value
}
