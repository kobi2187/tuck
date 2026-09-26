{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuckˑfnˑready*(): bool
proc tuckˑfnˑmain*(): int

type tuckˑactorˑAccumulatorMsgKind* = enum msgAdd, msgFinish, msgShutdown
type tuckˑactorˑAccumulatorMsg* = object
  tuckTag*: tuckˑactorˑAccumulatorMsgKind
  n*: int

type tuckˑactorˑAccumulator* = ref object
  total*: int
  done*: bool
  mailbox*: Mailbox[tuckˑactorˑAccumulatorMsg, 64]
  finished*: bool

let tuckˑactorˑAccumulatorSingleton* = tuckˑactorˑAccumulator(total: 0, done: false)

proc handleMsg*(self: tuckˑactorˑAccumulator, msg: tuckˑactorˑAccumulatorMsg) =
  case msg.tuckTag
  of msgAdd:
    let n = msg.n
    self.total = (self.total + n)
  of msgFinish:
    self.done = true
  of msgShutdown:
    self.total = self.total
    self.finished = true

proc draintuckˑactorˑAccumulator(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    if tuckˑactorˑAccumulatorSingleton.finished: return
    for m in messages(tuckˑactorˑAccumulatorSingleton.mailbox):
      handleMsg(tuckˑactorˑAccumulatorSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑAccumulatorSlot*: pointer
proc registerActortuckˑactorˑAccumulator*() =
  tuckˑactorˑAccumulatorSlot = tuckStartActor(draintuckˑactorˑAccumulator)

proc tuckˑfnˑready*(): bool =
  return tuckˑactorˑAccumulatorSingleton.done

proc tuckˑfnˑmain*(): int =
  for tuckˑvˑi in (1 .. 10):
    if true:
      discard enqueue(tuckˑactorˑAccumulatorSingleton.mailbox, tuckˑactorˑAccumulatorMsg(tuckTag: msgAdd, n: tuckˑvˑi))
      tuckNotifySend(tuckˑactorˑAccumulatorSlot)
  discard enqueue(tuckˑactorˑAccumulatorSingleton.mailbox, tuckˑactorˑAccumulatorMsg(tuckTag: msgFinish))
  tuckNotifySend(tuckˑactorˑAccumulatorSlot)
  tuckWaitOn(tuckˑactorˑAccumulatorSlot, tuckˑfnˑready)
  return tuckˑactorˑAccumulatorSingleton.total

