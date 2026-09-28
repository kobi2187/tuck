{.experimental: "codeReordering".}
import scheduler

proc tuckˑfnˑdone*(): bool
proc tuckˑfnˑmain*(): int

type tuckˑactorˑSinkMsgKind* = enum msgPing
type tuckˑactorˑSinkMsg* = object
  tuckTag*: tuckˑactorˑSinkMsgKind
  n*: int

type tuckˑactorˑSink* = ref object
  hits*: int
  mailbox*: Mailbox[tuckˑactorˑSinkMsg, 8]

let tuckˑactorˑSinkSingleton* = tuckˑactorˑSink(hits: 0)

proc handleMsg*(self: tuckˑactorˑSink, msg: tuckˑactorˑSinkMsg) =
  case msg.tuckTag
  of msgPing:
    let n = msg.n
    if true:
      self.hits = (self.hits + n)

proc draintuckˑactorˑSink(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑSinkSingleton.mailbox):
      handleMsg(tuckˑactorˑSinkSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑSinkSlot*: pointer
proc registerActortuckˑactorˑSink*() =
  tuckˑactorˑSinkSlot = tuckStartActor(draintuckˑactorˑSink)

proc tuckˑtaskˑfire*(): void =
  discard enqueue(tuckˑactorˑSinkSingleton.mailbox, tuckˑactorˑSinkMsg(tuckTag: msgPing, n: 5))
  tuckNotifySend(tuckˑactorˑSinkSlot)
  return

proc tuckˑfnˑdone*(): bool =
  return (tuckˑactorˑSinkSingleton.hits == 5)

proc tuckˑfnˑmain*(): int =
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuckˑtaskˑfire()))
  tuckWaitOn(tuckˑactorˑSinkSlot, tuckˑfnˑdone)
  scheduler.stop()
  return tuckˑactorˑSinkSingleton.hits

