{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuckˑfnˑsumReady*(): bool
proc tuckˑfnˑmain*(): int

type tuckˑactorˑCounterMsgKind* = enum msgAdd
type tuckˑactorˑCounterMsg* = object
  tuckTag*: tuckˑactorˑCounterMsgKind
  n*: int

type tuckˑactorˑCounter* = ref object
  total*: int
  mailbox*: Mailbox[tuckˑactorˑCounterMsg, 128]

let tuckˑactorˑCounterSingleton* = tuckˑactorˑCounter(total: 0)

proc handleMsg*(self: tuckˑactorˑCounter, msg: tuckˑactorˑCounterMsg) =
  case msg.tuckTag
  of msgAdd:
    let n = msg.n
    if true:
      self.total = (self.total + n)

proc draintuckˑactorˑCounter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑCounterSingleton.mailbox):
      handleMsg(tuckˑactorˑCounterSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑCounterSlot*: pointer
proc registerActortuckˑactorˑCounter*() =
  tuckˑactorˑCounterSlot = tuckStartActor(draintuckˑactorˑCounter)

proc tuckˑfnˑsumReady*(): bool =
  return (tuckˑactorˑCounterSingleton.total == 55)

proc tuckˑfnˑmain*(): int =
  for tuckˑvˑi in (1 .. 10):
    if true:
      discard enqueue(tuckˑactorˑCounterSingleton.mailbox, tuckˑactorˑCounterMsg(tuckTag: msgAdd, n: tuckˑvˑi))
      tuckNotifySend(tuckˑactorˑCounterSlot)
  tuckWaitOn(tuckˑactorˑCounterSlot, tuckˑfnˑsumReady)
  return tuckˑactorˑCounterSingleton.total

