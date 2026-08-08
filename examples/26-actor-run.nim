import ../compiler/tuck_rt
import scheduler

type tuck_CounterMsgKind* = enum msgAdd
type tuck_CounterMsg* = object
  kind*: tuck_CounterMsgKind
  n*: int

type tuck_Counter* = ref object
  total*: int
  mailbox*: Mailbox[tuck_CounterMsg, 128]

let tuck_CounterSingleton* = tuck_Counter()

proc handleMsg*(self: tuck_Counter, msg: tuck_CounterMsg) =
  case msg.kind
  of msgAdd:
    let n = msg.n
    if true:
      self.total = (self.total + n)

proc draintuck_Counter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_CounterMsg
    while dequeue(tuck_CounterSingleton.mailbox, m):
      handleMsg(tuck_CounterSingleton, m)
      result = true

proc registerActortuck_Counter*() =
  tuckStartActor(draintuck_Counter)

proc tuck_sumReady*(): bool =
  return (tuck_CounterSingleton.total == 55)

proc tuck_main*(): int =
  for i in (1 .. 10):
    if true:
      discard enqueue(tuck_CounterSingleton.mailbox, tuck_CounterMsg(kind: msgAdd, n: i))
      tuckNotifySend()
  scheduler.waitUntil(tuck_sumReady)
  return tuck_CounterSingleton.total

