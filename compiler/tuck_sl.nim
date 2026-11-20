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

proc tuckEventPost*(tag: uint8, val: uint32)  # forward; defined below
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
  f.next = nil
  if slTail == nil: slHead = f else: slTail.next = f
  slTail = f
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
  let f = slHead
  if f == nil: return false
  slHead = f.next
  if slHead == nil: slTail = nil
  tuckEventPost(2'u8, cast[uint32](cast[int](f)))
  tuckSlDrive(TuckHop(fn: f.stage, env: f))
  true

proc tuckSlRunAll*() =
  ## Run until nothing is ready: what `main` does before it returns, so a
  ## spawned task nobody awaits still runs to its end, as under minicoro.
  while tuckSlRunOne(): discard

# --- ISR-safe SPSC handoff -----------------------------------------------------
# A preallocated, single-slot mailbox. An ISR posts one word; a task takes it.
# No lock, no allocation: one producer and one consumer, so a volatile flag is
# enough. This is the allocation-free alternative to `send` from an ISR (which
# TK-EF07 forbids because a mailbox takes a lock).
const IsrSlotCount = 16
var isrSlotsValue {.global.}: array[IsrSlotCount, int]
var isrSlotsPending {.global.}: array[IsrSlotCount, bool]

proc tuckIsrPost*(slot: int, value: int) =
  ## Called from an ISR. Publish the value, then the flag: the barrier keeps
  ## the compiler and the CPU from reordering the two on Cortex-M.
  if slot < 0 or slot >= IsrSlotCount: return
  isrSlotsValue[slot] = value
  when defined(freestanding):
    {.emit: "__asm volatile(\"dmb\" ::: \"memory\");".}
  isrSlotsPending[slot] = true
  tuckEventPost(3'u8, cast[uint32](value))

proc tuckIsrTake*(slot: int): int =
  ## Called from task context: 0 when empty, else the posted value and clears
  ## the flag. Returns 0 as the empty sentinel, so post 0 as a bare signal.
  if slot < 0 or slot >= IsrSlotCount: return 0
  if not isrSlotsPending[slot]: return 0
  let v = isrSlotsValue[slot]
  isrSlotsPending[slot] = false
  v

# --- critical sections ---------------------------------------------------------
# A `critical:` block lowers to a pair of calls. On metal they disable and
# re-enable configurable interrupts (CPSID/CPSIE on Cortex-M); on a hosted
# build they are no-ops, because there is no ISR to exclude. Kept as a pair of
# procs rather than inline asm at every call site so nesting is a single place
# to change later (BASEPRI instead of PRIMASK).
proc tuckCriticalEnter*() {.inline.} =
  when defined(freestanding):
    {.emit: "__asm volatile(\"cpsid i\" ::: \"memory\");".}
  tuckEventPost(4'u8, 0)

proc tuckCriticalExit*() {.inline.} =
  when defined(freestanding):
    {.emit: "__asm volatile(\"cpsie i\" ::: \"memory\");".}
  tuckEventPost(5'u8, 0)

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
  const FreestandingHeapSize = 2048
  var freestandingHeap {.global.}: array[FreestandingHeapSize, byte]
  var freestandingHeapCursor {.global.}: int = 0
  proc alloc*(size: int): pointer =
    let aligned = (freestandingHeapCursor + 7) and (not 7)
    if aligned + size > FreestandingHeapSize:
      return nil
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
# A fixed-size, lock-free (single producer thread), non-intrusive event log.
# Every task switch, ISR post and critical section writes one word here instead
# of printing: printing changes timing, writing to a ring does not. The ring
# is drained at program end (or via semihosting) by `tuckEventDump`.
const EventRingSize = 256
var eventRingTag {.global.}: array[EventRingSize, uint8]
var eventRingVal {.global.}: array[EventRingSize, uint32]
var eventRingHead {.global.}: int = 0

proc tuckEventPost*(tag: uint8, val: uint32) =
  ## Record one event. Overwrites oldest when full (ring semantics).
  let i = eventRingHead mod EventRingSize
  eventRingTag[i] = tag
  eventRingVal[i] = val
  eventRingHead += 1

proc tuckEventDump*() =
  ## Print the ring's HEAD count over semihosting. The ring itself is
  ## verified by the count; per-event detail is decoded on the host by
  ## `tuck trace` (CTF export), not printed from the hot path.
  proc sh(s: cstring) {.importc: "tuck_semihost_write".}
  var buf: array[16, char]
  var j = 0
  buf[j] = 'E'; j += 1
  buf[j] = 'V'; j += 1
  buf[j] = 'T'; j += 1
  buf[j] = 'S'; j += 1
  buf[j] = '='; j += 1
  buf[j] = char(ord('0') + (eventRingHead mod 10)); j += 1
  buf[j] = '\n'; j += 1
  buf[j] = '\0'; j += 1
  sh(cast[cstring](addr buf[0]))
