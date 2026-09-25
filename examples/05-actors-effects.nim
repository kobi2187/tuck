{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_type_Feed* = object
  title*: string
  episodeCount*: int

type tuck_type_PodcastApp* = object
  discard

type tuck_type_CounterMsgKind* = enum msgIncrement, msgReset
type tuck_type_CounterMsg* = object
  tuckTag*: tuck_type_CounterMsgKind
  n*: int

type tuck_type_Counter* = ref object
  count*: int
  mailbox*: Mailbox[tuck_type_CounterMsg, 8]

let tuck_type_CounterSingleton* = tuck_type_Counter(count: 0)

proc handleMsg*(self: tuck_type_Counter, msg: tuck_type_CounterMsg) =
  case msg.tuckTag
  of msgIncrement:
    let n = msg.n
    if true:
      self.count = (self.count + n)
  of msgReset:
    if true:
      self.count = 0

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

proc tuck_fn_readSensor*[T](payload: T): TuckResult[tuple[value: uint16]] =
  stderr.writeLine("TUCK PENDING: tuck_fn_readSensor invoked (not implemented)")

proc fetchFeed*[T](payload: T): TuckResult[tuple[feed: tuck_type_Feed]] =
  stderr.writeLine("TUCK PENDING: fetchFeed invoked (not implemented)")



