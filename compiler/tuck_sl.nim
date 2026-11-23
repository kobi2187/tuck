## The STACKLESS runtime (#216, docs/stackless-concurrency.md): what code
## built with `--concurrency:stackless` runs on, in place of minicoro.
##
## A frame fn is a FRAME, a plain object whose first field is
## `TuckFrameHdr`, plus STAGES, `proc (env: pointer): TuckHop`. A hop is "run
## this stage on this frame next"; `tuckSlDrive` loops on it. Nothing switches
## stacks: a pause stores the frame somewhere (the ready list, a slot's
## waiter) and returns `tuckNoStep`, so the C stack unwinds to the driver.
##
## Memory is manual, as everything under `--mm:none`: frames come from one
## freelist per frame type and go back to it. Frames are HEAP frames; stack
## and slab frames are #219.
##
## PHASE 2 SCOPE. Ready list, yield, frame calls and task results. Parking on
## an fd, a timer or a mailbox is phase 4: until then a frame calling a
## parking extern blocks its thread exactly as `main` does.
import ./tuck_mem
import std/volatile   # the ISR slot: a polled flag must never be cached

proc tuckEventPost*(tag: uint8, val: uint32)  # forward; defined below
when defined(freestanding):
  proc tuckFatal*(msg: cstring) {.importc: "tuck_fatal", noreturn.}
    ## The one way a metal runtime check stops: the board prints `PANIC: msg`
    ## and traps, so the fault recorder reports it and `tuck sim` exits
    ## non-zero. Every freestanding failure path used to be a silent
    ## `while true` that read as a clean run (boards/startup_*.c defines it).
type
  TuckStageFn* = proc (env: pointer): TuckHop {.nimcall.}
  TuckHop* = object
    fn*: TuckStageFn
    env*: pointer

  TuckFrameHdr* = object
    ## The head of every frame: where it resumes, whom it returns to (nil: a
    ## task root), and its link in whatever queue holds it.
    stage*: TuckStageFn
    caller*: ptr TuckFrameHdr
    next*: ptr TuckFrameHdr
    embedded*: bool    ## built inside another frame or on main's stack
                       ## (#219): finishing it frees nothing

  TuckSlot*[T] = object
    ## A task's result. The task writes `value` and sets `done`; a frame
    ## awaiting it parks in `waiter`.
    value*: T
    done*: bool
    waiter*: ptr TuckFrameHdr

const tuckNoStep* = TuckHop()

# --- the ready list: an intrusive FIFO ------------------------------------------
when defined(freestanding):
  var slHead, slTail: ptr TuckFrameHdr
    ## Single thread on bare metal: no threadvar, no TLS read_tp.
else:
  var slHead {.threadvar.}, slTail {.threadvar.}: ptr TuckFrameHdr
    ## Per THREAD: a thread-mode actor's handler that spawns a task queues its
    ## frame on the actor's own thread, never on main's.

proc tuckSlReady*(f: ptr TuckFrameHdr) {.inline.} =
  ## Queue `f` to run its `stage` when the frames ahead of it have had theirs.
  ## On metal an interrupt may ready a frame (a `bind`'s event delivery), so
  ## the list is changed with interrupts masked (PRIMASK saved and restored).
  when defined(freestanding):
    var saved: uint32
    {.emit: "__asm volatile(\"mrs %0, primask\\n\\tcpsid i\" : \"=r\"(`saved`) :: \"memory\");".}
  f.next = nil
  if slTail == nil: slHead = f else: slTail.next = f
  slTail = f
  when defined(freestanding):
    {.emit: "__asm volatile(\"msr primask, %0\" :: \"r\"(`saved`) : \"memory\");".}
  tuckEventPost(1'u8, cast[uint32](cast[int](f)))

when defined(freestanding):
  var tuckSlDriving*: int
else:
  var tuckSlDriving* {.threadvar.}: int
  ## How many drivers are running stages on this thread. A blocking wait
  ## made inside a stage (`tuckLendUntil`) checks it: see tuckSlCannotPark.

proc tuckSlCannotPark*() {.noreturn.} =
  stderr.writeLine "tuck: a stackless stage waited inside the runtime outside a " &
    "helper stack (#216); build with --concurrency:stackful and report it"
  quit 70

proc tuckSlDrive*(h: TuckHop) {.inline.} =
  var h = h
  inc tuckSlDriving
  while h.fn != nil: h = h.fn(h.env)
  dec tuckSlDriving

proc tuckSlHasReady*(): bool {.inline.} = slHead != nil

proc tuckSlRunOne*(): bool =
  ## Run the first ready frame until it pauses or finishes. False: none ready.
  when defined(freestanding):
    var saved: uint32
    {.emit: "__asm volatile(\"mrs %0, primask\\n\\tcpsid i\" : \"=r\"(`saved`) :: \"memory\");".}
  let f = slHead
  if f != nil:
    slHead = f.next
    if slHead == nil: slTail = nil
  when defined(freestanding):
    {.emit: "__asm volatile(\"msr primask, %0\" :: \"r\"(`saved`) : \"memory\");".}
  if f == nil: return false
  tuckEventPost(2'u8, cast[uint32](cast[int](f)))
  tuckSlDrive(TuckHop(fn: f.stage, env: f))
  true

proc tuckSlRunAll*() =
  ## Run until nothing is ready: what `main` does before it returns, so a
  ## spawned task nobody awaits still runs to its end, as under minicoro.
  while tuckSlRunOne(): discard

# --- ISR-safe single-word handoff ---------------------------------------------
# A preallocated one-word mailbox per slot. An ISR posts; a task takes. No lock,
# no allocation: one producer and one consumer, so a volatile flag is enough —
# PROVIDED the producer never writes a slot the consumer has not emptied. The
# first version overwrote a pending value, so an ISR firing between the task's
# read and its clear lost the second word silently. Now a post to a full slot
# is dropped and COUNTED (`tuckIsrOverruns`): a lost interrupt is visible.
# Every access is volatile, so a polling loop cannot hoist the flag read.
const IsrSlotCount = 16
var isrSlotsValue {.global.}: array[IsrSlotCount, int]
var isrSlotsPending {.global.}: array[IsrSlotCount, bool]
var isrSlotsOverrun {.global.}: array[IsrSlotCount, uint32]

template tuckBarrier() =
  ## Compiler + memory barrier on metal. On a hosted build there is no ISR,
  ## and the volatile accesses already keep program order.
  when defined(freestanding):
    {.emit: "__asm volatile(\"dmb\" ::: \"memory\");".}

proc tuckIsrPost*(slot: int, value: int) =
  ## Called from an ISR. Value first, barrier, then the flag the task polls.
  if slot < 0 or slot >= IsrSlotCount: return
  if volatileLoad(addr isrSlotsPending[slot]):
    isrSlotsOverrun[slot] = isrSlotsOverrun[slot] + 1   # uint32: wraps, no trap
    return
  volatileStore(addr isrSlotsValue[slot], value)
  tuckBarrier()
  volatileStore(addr isrSlotsPending[slot], true)
  tuckEventPost(3'u8, cast[uint32](value))

proc tuckIsrTake*(slot: int): int =
  ## Called from task context: 0 when empty, else the posted value, and the
  ## slot is free again. 0 doubles as "empty", so post 0 only as a bare signal.
  if slot < 0 or slot >= IsrSlotCount: return 0
  if not volatileLoad(addr isrSlotsPending[slot]): return 0
  result = volatileLoad(addr isrSlotsValue[slot])
  tuckBarrier()
  volatileStore(addr isrSlotsPending[slot], false)

proc tuckIsrOverruns*(slot: int): int =
  ## Posts dropped because the slot was still full: interrupts the task
  ## never saw. Non-zero means the consumer is too slow for the ISR's rate.
  if slot < 0 or slot >= IsrSlotCount: return 0
  int(volatileLoad(addr isrSlotsOverrun[slot]))

# --- critical sections ---------------------------------------------------------
# A `critical:` block lowers to `let saved = tuckCriticalEnter()` and a
# `finally: tuckCriticalExit(saved)`. Enter returns the PRIMASK it found and
# masks; exit puts that value back. Restoring rather than unmasking is what
# makes nesting safe: an inner block's exit leaves interrupts off when an outer
# block (or an ISR, or startup code) had them off. On a hosted build there is
# no ISR to exclude, so both are no-ops and the saved state is 0. One pair of
# procs, not inline asm at every call site, so BASEPRI is a single change later.
proc tuckCriticalEnter*(): uint32 {.inline.} =
  when defined(freestanding):
    {.emit: "__asm volatile(\"mrs %0, primask\\n\\tcpsid i\" : \"=r\"(`result`) :: \"memory\");".}
  tuckEventPost(4'u8, result)

proc tuckCriticalExit*(saved: uint32) {.inline.} =
  # The event is recorded while still masked, so an ISR cannot interleave
  # its own ring write with this one.
  tuckEventPost(5'u8, saved)
  when defined(freestanding):
    {.emit: "__asm volatile(\"msr primask, %0\" :: \"r\"(`saved`) : \"memory\");".}

# --- volatile MMIO -------------------------------------------------------------
when defined(freestanding):
  proc tuckVolatileLoad*(p: ptr uint32): uint32 {.inline.} =
    {.emit: "`result` = *(volatile NU32*)`p`;".}

  proc tuckVolatileStore*(p: ptr uint32, v: uint32) {.inline.} =
    {.emit: "*(volatile NU32*)`p` = `v`;".}

# --- freestanding allocator -----------------------------------------------------
# Under --os:standalone there is no libc malloc. Provide a tiny bump allocator
# so the frame freelist (and any other alloc call) can obtain storage. Frames
# are normally reused from the freelist, so this is only hit on first use.
when defined(freestanding):
  const tuckHeapSize {.intdefine.} = 2048
    ## Bytes of frame storage. `-d:tuckHeapSize=N` sizes it per board: 2 KB is
    ## a quarter of an 8 KB part before the stack.
  var freestandingHeap {.global, align(8).}: array[tuckHeapSize, byte]
  var freestandingHeapCursor {.global.}: int = 0
  proc alloc*(size: int): pointer =
    ## Never returns nil: a caller that zeroes or links a nil frame writes
    ## through address 0, and 200 spawned tasks once vanished without a word.
    ## Never freed either (`dealloc` is a no-op); frames are reused from their
    ## per-type freelist, so the high-water mark is the live frame count.
    let aligned = (freestandingHeapCursor + 7) and (not 7)
    if aligned + size > tuckHeapSize:
      tuckFatal("tuck frame heap exhausted: more live tasks than -d:tuckHeapSize holds")
    result = addr freestandingHeap[aligned]
    freestandingHeapCursor = aligned + size
  proc allocShared0*(size: int): pointer = alloc(size)
  proc dealloc*(p: pointer) = discard

  proc tuckSlAwaitMain*[T](s: ptr TuckSlot[T]): T =
    ## Freestanding await: no reactor or OS loop, just drive the ready frames
    ## until the slot is filled. Matches tuck_async's version for a program
    ## with no fd/timer waits (the only kind that runs on metal today).
    while not s.done:
      tuckSlRunAll()
    tuckMove(s.value)

  proc tuckSlOnStack*(f: ptr TuckFrameHdr, next: TuckStageFn,
                      body: proc (env: pointer) {.nimcall.}): TuckHop =
    ## No helper stack on metal: a pausing statement runs inline on the caller's
    ## stack. Safe when the statement's waits are polled externs (our shims),
    ## which do not park a coroutine — they complete before returning.
    f.stage = next
    body(cast[pointer](f))
    TuckHop(fn: next, env: f)

# --- frames ---------------------------------------------------------------------
proc tuckSlFreeList[T](_: typedesc[T]): ptr ptr TuckFrameHdr {.inline.} =
  ## One freelist per frame type: a generic's global is per instantiation.
  var head {.global, threadvar.}: ptr TuckFrameHdr
  addr head

proc tuckSlAlloc*[T](_: typedesc[T]): ptr T {.inline.} =
  ## A zeroed frame of type T, reused from T's freelist when one is free.
  let fl = tuckSlFreeList(T)
  if fl[] != nil:
    result = cast[ptr T](fl[])
    fl[] = fl[].next
  else:
    result = cast[ptr T](alloc(sizeof(T)))
  zeroMem(result, sizeof(T))

proc tuckSlFree*[T](f: ptr T) {.inline.} =
  ## Back to T's freelist. What it owned was dropped or moved out already.
  let fl = tuckSlFreeList(T)
  let h = cast[ptr TuckFrameHdr](f)
  h.next = fl[]
  fl[] = h

proc tuckSlReturnHop*(f: ptr TuckFrameHdr): TuckHop {.inline.} =
  ## The hop a finishing frame returns: its caller's next stage, or nothing.
  let c = f.caller
  if c == nil: tuckNoStep else: TuckHop(fn: c.stage, env: c)

# --- results --------------------------------------------------------------------
proc tuckSlComplete*[T](s: ptr TuckSlot[T], v: sink T) {.inline.} =
  ## The task is done: its value lands in the slot and its awaiter wakes.
  tuckStore(s.value, v)
  s.done = true
  if s.waiter != nil:
    tuckSlReady(s.waiter)
    s.waiter = nil

proc tuckSlFinish*[T](slot: ptr TuckSlot[T], dest: ptr T, v: sink T) {.inline.} =
  ## Where a frame's return value goes: its task slot, its caller's
  ## destination, or nowhere (a spawned task nobody awaits: dropped).
  var v = v
  if slot != nil: tuckSlComplete(slot, tuckMove(v))
  elif dest != nil: tuckStore(dest[], tuckMove(v))
  else: tuckDrop(v)

proc tuckSlFinishVoid*(slot: ptr TuckSlot[bool]) {.inline.} =
  ## A void frame's end: a task root marks its slot done.
  if slot != nil: tuckSlComplete(slot, true)

# --- pauses ---------------------------------------------------------------------
proc tuckSlYield*(f: ptr TuckFrameHdr, next: TuckStageFn): TuckHop {.inline.} =
  ## The `[io]` yield before a call in a task body: requeue, let others run.
  f.stage = next
  tuckSlReady(f)
  tuckNoStep

proc tuckSlAwait*[T](f: ptr TuckFrameHdr, s: ptr TuckSlot[T],
                     next: TuckStageFn): TuckHop {.inline.} =
  ## Continue at `next` once the task behind `s` is done: at once if it is.
  f.stage = next
  if s.done: return TuckHop(fn: next, env: f)
  s.waiter = f
  tuckNoStep

# --- finishing a frame, from a `return` in a stage ---------------------------------
proc tuckSlRet*[F; T](f: ptr F, v: sink T): TuckHop {.inline.} =
  ## `return v` in a stage: the value goes where the frame's result goes,
  ## the frame is freed, and whoever resumes next is the hop.
  mixin tuckSlExit
  tuckSlFinish(f.tuckRes, f.tuckDest, v)
  tuckSlExit(f)              # its armed `defer`s (emitted per frame type)
  let h = cast[ptr TuckFrameHdr](f)
  result = tuckSlReturnHop(h)
  if not h.embedded: tuckSlFree(f)

proc tuckSlRetVoid*[F](f: ptr F): TuckHop {.inline.} =
  ## A void frame's `return` (or its end).
  mixin tuckSlExit
  tuckSlFinishVoid(f.tuckRes)
  tuckSlExit(f)
  let h = cast[ptr TuckFrameHdr](f)
  result = tuckSlReturnHop(h)
  if not h.embedded: tuckSlFree(f)

# --- event ring (T5) -------------------------------------------------------
# A fixed-size event log: task switches, ISR posts and critical sections write
# one tag + one word each instead of printing, because printing changes timing
# and a ring write does not. ON by default on metal (`-d:tuckNoEventRing`
# removes it), OFF by default on a hosted build (`-d:tuckEventRing` enables
# it): there, thread-mode actors post from several threads and the ring is
# not thread-safe, and every task switch would pay for a log nobody reads.
#
# Two producers on metal — task context and ISRs — so a post masks
# interrupts around its index bump; an unmasked read-increment could hand
# two events the same slot. The head is a uint32 that wraps: an `int` head
# trapped on overflow after 2^31 events, a few hours of a busy firmware.
const tuckEventRingSize* {.intdefine.} = 256
  ## Entries; a power of two. 256 costs 1280 bytes of RAM.
static: doAssert (tuckEventRingSize and (tuckEventRingSize - 1)) == 0,
  "-d:tuckEventRingSize must be a power of two"
const tuckEventRingOn* =
  (defined(freestanding) and not defined(tuckNoEventRing)) or defined(tuckEventRing)

when tuckEventRingOn:
  var eventRingTag {.global.}: array[tuckEventRingSize, uint8]
  var eventRingVal {.global.}: array[tuckEventRingSize, uint32]
var eventRingHead {.global.}: uint32 = 0

proc tuckEventPost*(tag: uint8, val: uint32) =
  ## Record one event; overwrites the oldest when full (ring semantics).
  when tuckEventRingOn:
    when defined(freestanding):
      var mask: uint32
      {.emit: "__asm volatile(\"mrs %0, primask\\n\\tcpsid i\" : \"=r\"(`mask`) :: \"memory\");".}
    let i = int(eventRingHead and uint32(tuckEventRingSize - 1))
    eventRingTag[i] = tag
    eventRingVal[i] = val
    eventRingHead = eventRingHead + 1
    when defined(freestanding):
      {.emit: "__asm volatile(\"msr primask, %0\" :: \"r\"(`mask`) : \"memory\");".}
  else:
    discard tag
    discard val

proc tuckEventCount*(): uint32 =
  ## Events posted since boot (mod 2^32), whether or not the ring still holds
  ## them. 0 when the ring is compiled out.
  eventRingHead

proc tuckEventDump*() =
  ## Print `EVTS=<count>` (decimal) over semihosting. Per-event detail is
  ## decoded on the host by `tuck trace`, not printed from the hot path.
  proc sh(s: cstring) {.importc: "tuck_board_puts".}   # the board's console
  var buf: array[24, char]
  var digits: array[10, char]
  var n = eventRingHead
  var d = 0
  while true:
    digits[d] = char(ord('0') + int(n mod 10))
    d += 1
    n = n div 10
    if n == 0: break
  var j = 0
  for c in "EVTS=":
    buf[j] = c
    j += 1
  while d > 0:
    d -= 1
    buf[j] = digits[d]
    j += 1
  buf[j] = '\n'
  buf[j + 1] = '\0'
  sh(cast[cstring](addr buf[0]))
