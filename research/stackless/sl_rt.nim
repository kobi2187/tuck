## SPIKE — a minimal stackless runtime, the shape issue #216's transform
## would target. Not wired into the compiler; see README.md here.
##
## A suspending fn becomes a FRAME (a plain object whose first field is
## `FrameHdr`) and a few STAGES (`proc (env: pointer): Hop`). A `Hop` is "run
## this stage on this frame next"; `drive` loops on it. Nothing here switches
## stacks: a pause stores the frame somewhere (the ready list, a slot's
## waiter) and returns `noStep`, so the C stack unwinds back to `drive`.
##
## Memory is manual, as in tuck_rt under `--mm:none`: frames come from a
## per-type freelist (`frameAlloc` / `frameFree`) and are never traced. The
## same code ports to Odin and D line for line — no closures, no GC.

type
  StageFn* = proc (env: pointer): Hop {.nimcall.}
  Hop* = object
    fn*: StageFn
    env*: pointer

  FrameHdr* = object
    ## The head of every frame. `stage` is where it resumes; `caller` is the
    ## frame to resume when this one returns (nil: a task root); `next` links
    ## it into whatever queue currently owns it.
    stage*: StageFn
    caller*: ptr FrameHdr
    next*: ptr FrameHdr

  Slot*[T] = object
    ## A task's result. The task writes `value` and sets `done`; a frame
    ## awaiting it parks in `waiter`.
    value*: T
    done*: bool
    waiter*: ptr FrameHdr

const noStep* = Hop()

# --- the ready list (intrusive FIFO) -----------------------------------------
var readyHead, readyTail: ptr FrameHdr

proc ready*(f: ptr FrameHdr) {.inline.} =
  f.next = nil
  if readyTail == nil: readyHead = f else: readyTail.next = f
  readyTail = f

proc drive*(h: Hop) {.inline.} =
  var h = h
  while h.fn != nil: h = h.fn(h.env)

proc runOne*(): bool {.inline.} =
  ## Run the first ready frame until it parks or finishes. False: none ready.
  let f = readyHead
  if f == nil: return false
  readyHead = f.next
  if readyHead == nil: readyTail = nil
  drive(Hop(fn: f.stage, env: f))
  true

proc runAll*() =
  while runOne(): discard

# --- frames -------------------------------------------------------------------
proc freeListOf[T](_: typedesc[T]): ptr ptr FrameHdr {.inline.} =
  ## One freelist per frame type (a generic's global is per instantiation).
  var head {.global.}: ptr FrameHdr
  addr head

proc frameAlloc*[T](_: typedesc[T]): ptr T {.inline.} =
  ## A frame of type T, from T's freelist when one is free. Header zeroed.
  let fl = freeListOf(T)
  if fl[] != nil:
    result = cast[ptr T](fl[])
    fl[] = fl[].next
  else:
    result = cast[ptr T](alloc(sizeof(T)))
  result.hdr = FrameHdr()

proc frameFree*[T](f: ptr T) {.inline.} =
  ## Back to T's freelist. Fields were moved out or dropped by the stage.
  let fl = freeListOf(T)
  f.hdr.next = fl[]
  fl[] = cast[ptr FrameHdr](f)

template returnTo*(f: ptr FrameHdr): Hop =
  ## The hop a finishing frame returns: its caller's next stage, or nothing.
  (let c = f.caller; if c == nil: noStep else: Hop(fn: c.stage, env: c))

# --- pause primitives ---------------------------------------------------------
template yieldTo*(f: ptr FrameHdr, next: StageFn): Hop =
  ## `[io]` with nothing to wait on: requeue and let the others run.
  f.stage = next
  ready(f)
  noStep

proc awaitSlot*[T](f: ptr FrameHdr, s: ptr Slot[T], next: StageFn): Hop {.inline.} =
  ## Continue at `next` once `s` is done: at once if it already is.
  f.stage = next
  if s.done: return Hop(fn: next, env: f)
  s.waiter = f
  noStep

proc complete*[T](s: ptr Slot[T], v: T) {.inline.} =
  s.value = v
  s.done = true
  if s.waiter != nil:
    ready(s.waiter)
    s.waiter = nil

proc awaitFromMain*[T](s: ptr Slot[T]): T =
  ## main is not a frame: it lends its thread to the scheduler until `s` is
  ## done (today's A94 rule, unchanged).
  while not s.done:
    if not runOne(): doAssert false, "deadlock: awaited slot never completes"
  s.value
