{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_Feed* = object
  title*: string
  episodeCount*: int

type tuck_PodcastApp* = object
  discard

type tuck_CounterMsgKind* = enum msgIncrement, msgReset
type tuck_CounterMsg* = object
  tuckTag*: tuck_CounterMsgKind
  n*: int

type tuck_Counter* = ref object
  count*: int
  mailbox*: Mailbox[tuck_CounterMsg, 8]

let tuck_CounterSingleton* = tuck_Counter()

proc handleMsg*(self: tuck_Counter, msg: tuck_CounterMsg) =
  case msg.tuckTag
  of msgIncrement:
    let n = msg.n
    if true:
      self.count = (self.count + n)
  of msgReset:
    if true:
      self.count = 0

proc draintuck_Counter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_CounterMsg
    while dequeue(tuck_CounterSingleton.mailbox, m):
      handleMsg(tuck_CounterSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_CounterSlot*: pointer
proc registerActortuck_Counter*() =
  tuck_CounterSlot = tuckStartActor(draintuck_Counter)

proc tuck_readSensor*[T](payload: T): TuckResult[tuple[value: uint16]] =
  stderr.writeLine("TUCK PENDING: tuck_readSensor invoked (not implemented)")

proc fetchFeed*[T](payload: T): TuckResult[tuple[feed: tuck_Feed]] =
  stderr.writeLine("TUCK PENDING: fetchFeed invoked (not implemented)")



