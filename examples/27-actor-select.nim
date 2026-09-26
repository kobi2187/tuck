{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_fn_ready*(): bool
proc tuck_fn_main*(): int

type tuck_type_AccumulatorMsgKind* = enum msgAdd, msgFinish, msgShutdown
type tuck_type_AccumulatorMsg* = object
  tuckTag*: tuck_type_AccumulatorMsgKind
  n*: int

type tuck_type_Accumulator* = ref object
  total*: int
  done*: bool
  mailbox*: Mailbox[tuck_type_AccumulatorMsg, 64]
  finished*: bool

let tuck_type_AccumulatorSingleton* = tuck_type_Accumulator(total: 0, done: false)

proc handleMsg*(self: tuck_type_Accumulator, msg: tuck_type_AccumulatorMsg) =
  case msg.tuckTag
  of msgAdd:
    let n = msg.n
    self.total = (self.total + n)
  of msgFinish:
    self.done = true
  of msgShutdown:
    self.total = self.total
    self.finished = true

proc draintuck_type_Accumulator(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    if tuck_type_AccumulatorSingleton.finished: return
    for m in messages(tuck_type_AccumulatorSingleton.mailbox):
      handleMsg(tuck_type_AccumulatorSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_AccumulatorSlot*: pointer
proc registerActortuck_type_Accumulator*() =
  tuck_type_AccumulatorSlot = tuckStartActor(draintuck_type_Accumulator)

proc tuck_fn_ready*(): bool =
  return tuck_type_AccumulatorSingleton.done

proc tuck_fn_main*(): int =
  for tuck_i in (1 .. 10):
    if true:
      discard enqueue(tuck_type_AccumulatorSingleton.mailbox, tuck_type_AccumulatorMsg(tuckTag: msgAdd, n: tuck_i))
      tuckNotifySend(tuck_type_AccumulatorSlot)
  discard enqueue(tuck_type_AccumulatorSingleton.mailbox, tuck_type_AccumulatorMsg(tuckTag: msgFinish))
  tuckNotifySend(tuck_type_AccumulatorSlot)
  tuckWaitOn(tuck_type_AccumulatorSlot, tuck_fn_ready)
  return tuck_type_AccumulatorSingleton.total

