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

  TuckSlot*[T] = object
    ## A task's result. The task writes `value` and sets `done`; a frame
    ## awaiting it parks in `waiter`.
    value*: T
    done*: bool
    waiter*: ptr TuckFrameHdr

const tuckNoStep* = TuckHop()

# --- the ready list: an intrusive FIFO ------------------------------------------
var slHead, slTail: ptr TuckFrameHdr

proc tuckSlReady*(f: ptr TuckFrameHdr) {.inline.} =
  ## Queue `f` to run its `stage` when the frames ahead of it have had theirs.
  f.next = nil
  if slTail == nil: slHead = f else: slTail.next = f
  slTail = f

var tuckSlDriving* {.threadvar.}: int
  ## How many drivers are running stages on this thread. A blocking wait
  ## made inside a stage (`tuckLendUntil`) checks it: see tuckSlCannotPark.

proc tuckSlCannotPark*() {.noreturn.} =
  stderr.writeLine "tuck: a stackless task waited on I/O or a timer; parking a " &
    "frame arrives in #216 phase 4 (build with --concurrency:stackful for now)"
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
  tuckSlDrive(TuckHop(fn: f.stage, env: f))
  true

proc tuckSlRunAll*() =
  ## Run until nothing is ready: what `main` does before it returns, so a
  ## spawned task nobody awaits still runs to its end, as under minicoro.
  while tuckSlRunOne(): discard

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
  result = tuckSlReturnHop(cast[ptr TuckFrameHdr](f))
  tuckSlFree(f)

proc tuckSlRetVoid*[F](f: ptr F): TuckHop {.inline.} =
  ## A void frame's `return` (or its end).
  mixin tuckSlExit
  tuckSlFinishVoid(f.tuckRes)
  tuckSlExit(f)
  result = tuckSlReturnHop(cast[ptr TuckFrameHdr](f))
  tuckSlFree(f)
