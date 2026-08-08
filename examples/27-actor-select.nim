import ../compiler/tuck_rt
import scheduler

type tuck_AccumulatorMsgKind* = enum msgAdd, msgFinish, msgShutdown
type tuck_AccumulatorMsg* = object
  kind*: tuck_AccumulatorMsgKind
  n*: int

type tuck_Accumulator* = ref object
    total*: int
    done*: bool
    mailbox*: Mailbox[tuck_AccumulatorMsg, 64]
    finished*: bool

let tuck_AccumulatorSingleton* = tuck_Accumulator()

proc handleMsg*(self: tuck_Accumulator, msg: tuck_AccumulatorMsg) =
  case msg.kind
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
    var m: tuck_AccumulatorMsg
    while dequeue(tuck_AccumulatorSingleton.mailbox, m):
      handleMsg(tuck_AccumulatorSingleton, m)
      result = true

proc registerActortuck_Accumulator*() =
  tuckStartActor(draintuck_Accumulator)

proc tuck_ready*(): bool =
  return tuck_AccumulatorSingleton.done

proc tuck_main*(): int =
  for i in (1 .. 10):
    if true:
      discard enqueue(tuck_AccumulatorSingleton.mailbox, tuck_AccumulatorMsg(kind: msgAdd, n: i))
      tuckNotifySend()
  discard enqueue(tuck_AccumulatorSingleton.mailbox, tuck_AccumulatorMsg(kind: msgFinish))
  tuckNotifySend()
  scheduler.waitUntil(tuck_ready)
  return tuck_AccumulatorSingleton.total

