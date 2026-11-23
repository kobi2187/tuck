# compiler/tuck_actors_metal.nim — included by tuck_rt on a freestanding build.
#
# Actors on bare metal (bare-metal roadmap 2.0). The hosted mailbox
# (tuck_rt_stdlib_externs) is built for threads: two buffers swapped under a
# spin lock, padded so two cores never share a cache line. A Cortex-M has one
# core and, below the M7, no data cache, so none of that buys anything; the
# hosted file also carries files, sockets and threads, which is why it is not
# compiled here at all.
#
# What an actor costs here: its state, plus `[queue: N]` messages, plus two
# 16-bit indices. A message is its tag and its fields.
#
# Each actor is a FRAME on the stackless scheduler (tuck_sl): a send queues the
# frame if it is not queued already; running it drains what was waiting when
# it started, so a handler that sends to its own actor is taken next pass, not
# in an endless loop. Every mailbox access is under `critical:` (PRIMASK saved
# and restored), so an interrupt may send once `bind` lets one.

type
  Mailbox*[T; Cap: static int] = object
    ## A ring of `Cap` messages. Zero-initialised is a valid empty mailbox.
    buf*: array[Cap, T]
    head*: uint16          ## the oldest message
    count*: uint16         ## messages waiting

  DrainProc* = proc (): bool {.nimcall, gcsafe.}
    ## The actor's emitted drain: handle what is waiting; true if it handled any.

  ActorSlot = object
    frame: TuckFrameHdr    ## first: the scheduler runs this header
    drain: DrainProc
    queued: bool

static: doAssert sizeof(Mailbox[uint8, 4]) == 4 + 4,
  "a metal mailbox is its messages plus two 16-bit indices"

const tuckMaxActors* {.intdefine.} = 16
  ## Slots for actors, allocated statically: `-d:tuckMaxActors=N`.

var actorSlots {.global.}: array[tuckMaxActors, ActorSlot]
var actorSlotCount {.global.}: int

proc enqueue*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T): bool =
  ## False when the mailbox is full and the message was not taken; the
  ## actor's `on_full` decides what then.
  let saved = tuckCriticalEnter()
  if int(mb.count) >= Cap:
    tuckCriticalExit(saved)
    return false
  let at = (int(mb.head) + int(mb.count)) mod Cap
  mb.buf[at] = msg
  mb.count = mb.count + 1
  tuckCriticalExit(saved)
  true

proc takeOne[T; Cap: static int](mb: var Mailbox[T, Cap], msg: var T): bool =
  let saved = tuckCriticalEnter()
  if mb.count == 0:
    tuckCriticalExit(saved)
    return false
  msg = mb.buf[int(mb.head)]
  mb.head = uint16((int(mb.head) + 1) mod Cap)
  mb.count = mb.count - 1
  tuckCriticalExit(saved)
  true

iterator messages*[T; Cap: static int](mb: var Mailbox[T, Cap]): T =
  ## The messages waiting when the drain began, oldest first, each copied out
  ## before its handler runs (so a handler may send to this same mailbox).
  var n = 0
  block:
    let saved = tuckCriticalEnter()
    n = int(mb.count)
    tuckCriticalExit(saved)
  var m: T
  for i in 0 ..< n:
    if not takeOne(mb, m): break
    yield m

proc hasRoom*[T; Cap: static int](mb: var Mailbox[T, Cap]): bool =
  int(mb.count) < Cap

proc flushNow*[T; Cap: static int](mb: var Mailbox[T, Cap]) = discard
  ## Every send is handed over as it is made: nothing is staged.

proc tuckCheckWaiters*() = discard
  ## A waiter here is main itself, re-testing between scheduler passes.

proc actorFrameStage(env: pointer): TuckHop {.nimcall.} =
  ## One pass: drain until empty, then leave the ready list. A send made
  ## during the pass finds the actor queued and only enqueues.
  let slot = cast[ptr ActorSlot](env)
  while slot.drain(): discard
  slot.queued = false
  tuckNoStep

proc tuckStartActorFrame*(drain: DrainProc): pointer {.discardable.} =
  ## Called once per actor, before main.
  if actorSlotCount >= tuckMaxActors:
    tuckFatal("more actors than -d:tuckMaxActors")
  let slot = addr actorSlots[actorSlotCount]
  inc actorSlotCount
  slot.drain = drain
  slot.frame.stage = actorFrameStage
  slot.queued = true
  tuckSlReady(addr slot.frame)
  cast[pointer](slot)

proc tuckNotifySend*(handle: pointer) =
  ## After a send: put the actor on the ready list unless it already is.
  if handle == nil: return
  let slot = cast[ptr ActorSlot](handle)
  let saved = tuckCriticalEnter()
  if not slot.queued:
    slot.queued = true
    tuckSlReady(addr slot.frame)
  tuckCriticalExit(saved)

proc tuckMailboxFull*(actor: cstring, why: cstring) {.noreturn.} =
  discard actor
  discard why
  tuckFatal("an actor's mailbox is full and it declares `on_full: assert`")

proc sendWaiting*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T,
                                       handle: pointer, actor: cstring) =
  ## `on_full: wait`: run the scheduler until the receiver has made room. A
  ## receiver that never runs is a deadlock, and stops the program loudly.
  while not enqueue(mb, msg):
    tuckNotifySend(handle)
    if not tuckSlRunOne():
      tuckFatal("a send waits on a full mailbox that nothing will drain")

proc sendAsserting*[T; Cap: static int](mb: var Mailbox[T, Cap], msg: T,
                                         actor: cstring) =
  if not enqueue(mb, msg):
    tuckMailboxFull(actor, "")

proc tuckDrainActors*() =
  ## After main: let every actor finish what was sent to it.
  tuckSlRunAll()

proc tuckWaitOn*(handle: pointer, pred: proc (): bool {.nimcall.}) =
  ## `Actor.waitUntil {pred: :p}`: main runs the scheduler until `p` holds. A
  ## condition still false with nothing left to run never will be: stop loudly
  ## rather than spin.
  discard handle
  while not pred():
    if not tuckSlRunOne():
      tuckFatal("waitUntil: nothing left to run and the condition is still false")
