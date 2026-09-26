{.experimental: "codeReordering".}
import scheduler

proc tuck_fn_done*(): bool
proc tuck_fn_main*(): int

type tuck_type_SinkMsgKind* = enum msgPing
type tuck_type_SinkMsg* = object
  tuckTag*: tuck_type_SinkMsgKind
  n*: int

type tuck_type_Sink* = ref object
  hits*: int
  mailbox*: Mailbox[tuck_type_SinkMsg, 8]

let tuck_type_SinkSingleton* = tuck_type_Sink(hits: 0)

proc handleMsg*(self: tuck_type_Sink, msg: tuck_type_SinkMsg) =
  case msg.tuckTag
  of msgPing:
    let n = msg.n
    if true:
      self.hits = (self.hits + n)

proc draintuck_type_Sink(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_SinkSingleton.mailbox):
      handleMsg(tuck_type_SinkSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_SinkSlot*: pointer
proc registerActortuck_type_Sink*() =
  tuck_type_SinkSlot = tuckStartActor(draintuck_type_Sink)

proc tuck_fn_fire*(): void =
  discard enqueue(tuck_type_SinkSingleton.mailbox, tuck_type_SinkMsg(tuckTag: msgPing, n: 5))
  tuckNotifySend(tuck_type_SinkSlot)
  return

proc tuck_fn_done*(): bool =
  return (tuck_type_SinkSingleton.hits == 5)

proc tuck_fn_main*(): int =
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_fn_fire()))
  tuckWaitOn(tuck_type_SinkSlot, tuck_fn_done)
  scheduler.stop()
  return tuck_type_SinkSingleton.hits

