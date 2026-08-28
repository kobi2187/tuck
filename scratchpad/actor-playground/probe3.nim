import ../../compiler/tuck_async
import ../../compiler/tuck_rt
import scheduler

type tuck_BigMsgKind* = enum msgPing
type tuck_BigMsg* = object
  kind*: tuck_BigMsgKind
  n*: int

type tuck_Big* = ref object
  got*: int
  mailbox*: Mailbox[tuck_BigMsg, 128]

let tuck_BigSingleton* = tuck_Big()

proc handleMsg*(self: tuck_Big, msg: tuck_BigMsg) =
  case msg.kind
  of msgPing:
    let n = msg.n
    if true:
      self.got = (self.got + n)

proc draintuck_Big(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_BigMsg
    while dequeue(tuck_BigSingleton.mailbox, m):
      handleMsg(tuck_BigSingleton, m)
      result = true

proc registerActortuck_Big*() =
  tuckStartActor(draintuck_Big)

proc tuck_done*(): bool =
  return (tuck_BigSingleton.got >= 10)

proc tuck_main*(): int =
  for i in (1 .. 10):
    if true:
      discard enqueue(tuck_BigSingleton.mailbox, tuck_BigMsg(kind: msgPing, n: 1))
      tuckNotifySend()
  scheduler.waitUntil(tuck_done)
  return tuck_BigSingleton.got


when isMainModule:
  tuckAsyncInit()
  registerActortuck_Big()
  quit(tuck_main())
