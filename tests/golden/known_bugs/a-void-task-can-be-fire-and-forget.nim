import scheduler

type tuck_SinkMsgKind* = enum msgPing
type tuck_SinkMsg* = object
  kind*: tuck_SinkMsgKind
  n*: int

type tuck_Sink* = ref object
  hits*: int
  mailbox*: Mailbox[tuck_SinkMsg, 8]

let tuck_SinkSingleton* = tuck_Sink()

proc handleMsg*(self: tuck_Sink, msg: tuck_SinkMsg) =
  case msg.kind
  of msgPing:
    let n = msg.n
    if true:
      self.hits = (self.hits + n)

proc draintuck_Sink(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_SinkMsg
    while dequeue(tuck_SinkSingleton.mailbox, m):
      handleMsg(tuck_SinkSingleton, m)
      result = true

proc registerActortuck_Sink*() =
  tuckStartActor(draintuck_Sink)

proc tuck_fire*(): void =
  discard enqueue(tuck_SinkSingleton.mailbox, tuck_SinkMsg(kind: msgPing, n: 5))
  tuckNotifySend()
  return

proc tuck_done*(): bool =
  return (tuck_SinkSingleton.hits == 5)

proc tuck_main*(): int =
  tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_fire()))
  scheduler.waitUntil(tuck_done)
  scheduler.stop()
  return tuck_SinkSingleton.hits

