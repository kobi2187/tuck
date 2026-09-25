{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_sumReady*(): bool
proc tuck_main*(): int

type tuck_CounterMsgKind* = enum msgAdd
type tuck_CounterMsg* = object
  tuckTag*: tuck_CounterMsgKind
  n*: int

type tuck_Counter* = ref object
  total*: int
  mailbox*: Mailbox[tuck_CounterMsg, 128]

let tuck_CounterSingleton* = tuck_Counter(total: 0)

proc handleMsg*(self: tuck_Counter, msg: tuck_CounterMsg) =
  case msg.tuckTag
  of msgAdd:
    let n = msg.n
    if true:
      self.total = (self.total + n)

proc draintuck_Counter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_CounterSingleton.mailbox):
      handleMsg(tuck_CounterSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_CounterSlot*: pointer
proc registerActortuck_Counter*() =
  tuck_CounterSlot = tuckStartActor(draintuck_Counter)

proc tuck_sumReady*(): bool =
  return (tuck_CounterSingleton.total == 55)

proc tuck_main*(): int =
  for tuck_i in (1 .. 10):
    if true:
      discard enqueue(tuck_CounterSingleton.mailbox, tuck_CounterMsg(tuckTag: msgAdd, n: tuck_i))
      tuckNotifySend(tuck_CounterSlot)
  tuckWaitOn(tuck_CounterSlot, tuck_sumReady)
  return tuck_CounterSingleton.total

