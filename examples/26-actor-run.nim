{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import scheduler

proc tuck_fn_sumReady*(): bool
proc tuck_fn_main*(): int

type tuck_type_CounterMsgKind* = enum msgAdd
type tuck_type_CounterMsg* = object
  tuckTag*: tuck_type_CounterMsgKind
  n*: int

type tuck_type_Counter* = ref object
  total*: int
  mailbox*: Mailbox[tuck_type_CounterMsg, 128]

let tuck_type_CounterSingleton* = tuck_type_Counter(total: 0)

proc handleMsg*(self: tuck_type_Counter, msg: tuck_type_CounterMsg) =
  case msg.tuckTag
  of msgAdd:
    let n = msg.n
    if true:
      self.total = (self.total + n)

proc draintuck_type_Counter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_CounterSingleton.mailbox):
      handleMsg(tuck_type_CounterSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_CounterSlot*: pointer
proc registerActortuck_type_Counter*() =
  tuck_type_CounterSlot = tuckStartActor(draintuck_type_Counter)

proc tuck_fn_sumReady*(): bool =
  return (tuck_type_CounterSingleton.total == 55)

proc tuck_fn_main*(): int =
  for tuck_i in (1 .. 10):
    if true:
      discard enqueue(tuck_type_CounterSingleton.mailbox, tuck_type_CounterMsg(tuckTag: msgAdd, n: tuck_i))
      tuckNotifySend(tuck_type_CounterSlot)
  tuckWaitOn(tuck_type_CounterSlot, tuck_fn_sumReady)
  return tuck_type_CounterSingleton.total

