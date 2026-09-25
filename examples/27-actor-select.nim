{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_ready*(): bool
proc tuck_main*(): int

type tuck_AccumulatorMsgKind* = enum msgAdd, msgFinish, msgShutdown
type tuck_AccumulatorMsg* = object
  tuckTag*: tuck_AccumulatorMsgKind
  n*: int

type tuck_Accumulator* = ref object
  total*: int
  done*: bool
  mailbox*: Mailbox[tuck_AccumulatorMsg, 64]
  finished*: bool

let tuck_AccumulatorSingleton* = tuck_Accumulator(total: 0, done: false)

proc handleMsg*(self: tuck_Accumulator, msg: tuck_AccumulatorMsg) =
  case msg.tuckTag
  of msgAdd:
    let n = msg.n
    self.total = (self.total + n)
  of msgFinish:
    self.done = true
  of msgShutdown:
    self.total = self.total
    self.finished = true

proc draintuck_Accumulator(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    if tuck_AccumulatorSingleton.finished: return
    for m in messages(tuck_AccumulatorSingleton.mailbox):
      handleMsg(tuck_AccumulatorSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_AccumulatorSlot*: pointer
proc registerActortuck_Accumulator*() =
  tuck_AccumulatorSlot = tuckStartActor(draintuck_Accumulator)

proc tuck_ready*(): bool =
  return tuck_AccumulatorSingleton.done

proc tuck_main*(): int =
  for tuck_i in (1 .. 10):
    if true:
      discard enqueue(tuck_AccumulatorSingleton.mailbox, tuck_AccumulatorMsg(tuckTag: msgAdd, n: tuck_i))
      tuckNotifySend(tuck_AccumulatorSlot)
  discard enqueue(tuck_AccumulatorSingleton.mailbox, tuck_AccumulatorMsg(tuckTag: msgFinish))
  tuckNotifySend(tuck_AccumulatorSlot)
  tuckWaitOn(tuck_AccumulatorSlot, tuck_ready)
  return tuck_AccumulatorSingleton.total

