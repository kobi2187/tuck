import ../../compiler/tuck_async
import ../../compiler/tuck_rt
import scheduler

type tuck_SmallMsgKind* = enum msgPing
type tuck_SmallMsg* = object
  kind*: tuck_SmallMsgKind
  n*: int

type tuck_Small* = ref object
  got*: int
  mailbox*: Mailbox[tuck_SmallMsg, 4]

let tuck_SmallSingleton* = tuck_Small()

proc handleMsg*(self: tuck_Small, msg: tuck_SmallMsg) =
  case msg.kind
  of msgPing:
    let n = msg.n
    if true:
      self.got = (self.got + n)

proc draintuck_Small(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_SmallMsg
    while dequeue(tuck_SmallSingleton.mailbox, m):
      handleMsg(tuck_SmallSingleton, m)
      result = true

proc registerActortuck_Small*() =
  tuckStartActor(draintuck_Small)

proc tuck_done*(): bool =
  return (tuck_SmallSingleton.got >= 10)

proc tuck_main*(): int =
  for i in (1 .. 10):
    if true:
      discard enqueue(tuck_SmallSingleton.mailbox, tuck_SmallMsg(kind: msgPing, n: 1))
      tuckNotifySend()
  scheduler.waitUntil(tuck_done)
  return tuck_SmallSingleton.got


when isMainModule:
  tuckAsyncInit()
  registerActortuck_Small()
  quit(tuck_main())
