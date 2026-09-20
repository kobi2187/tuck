{.experimental: "codeReordering".}
import scheduler

proc tuck_done*(): bool
proc tuck_main*(): int

type tuck_SinkMsgKind* = enum msgPing
type tuck_SinkMsg* = object
  tuckTag*: tuck_SinkMsgKind
  n*: int

type tuck_Sink* = ref object
  hits*: int
  mailbox*: Mailbox[tuck_SinkMsg, 8]

let tuck_SinkSingleton* = tuck_Sink()

proc handleMsg*(self: tuck_Sink, msg: tuck_SinkMsg) =
  case msg.tuckTag
  of msgPing:
    let n = msg.n
    if true:
      self.hits = (self.hits + n)

proc draintuck_Sink(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_SinkSingleton.mailbox):
      handleMsg(tuck_SinkSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_SinkSlot*: pointer
proc registerActortuck_Sink*() =
  tuck_SinkSlot = tuckStartActor(draintuck_Sink)

proc tuck_fire*(): void =
  discard enqueue(tuck_SinkSingleton.mailbox, tuck_SinkMsg(tuckTag: msgPing, n: 5))
  tuckNotifySend()
  return

proc tuck_done*(): bool =
  return (tuck_SinkSingleton.hits == 5)

proc tuck_main*(): int =
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_fire()))
  tuckWaitOn(tuck_SinkSlot, tuck_done)
  scheduler.stop()
  return tuck_SinkSingleton.hits

