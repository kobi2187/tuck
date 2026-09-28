{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuckˑtypeˑFeed* = object
  title*: string
  episodeCount*: int

type tuckˑobjectˑPodcastApp* = object
  discard

type tuckˑactorˑCounterMsgKind* = enum msgIncrement, msgReset
type tuckˑactorˑCounterMsg* = object
  tuckTag*: tuckˑactorˑCounterMsgKind
  n*: int

type tuckˑactorˑCounter* = ref object
  count*: int
  mailbox*: Mailbox[tuckˑactorˑCounterMsg, 8]

let tuckˑactorˑCounterSingleton* = tuckˑactorˑCounter(count: 0)

proc handleMsg*(self: tuckˑactorˑCounter, msg: tuckˑactorˑCounterMsg) =
  case msg.tuckTag
  of msgIncrement:
    let n = msg.n
    if true:
      self.count = (self.count + n)
  of msgReset:
    if true:
      self.count = 0

proc draintuckˑactorˑCounter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑCounterSingleton.mailbox):
      handleMsg(tuckˑactorˑCounterSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑCounterSlot*: pointer
proc registerActortuckˑactorˑCounter*() =
  tuckˑactorˑCounterSlot = tuckStartActor(draintuckˑactorˑCounter)

proc tuckˑfnˑreadSensor*[T](payload: T): TuckResult[tuple[value: uint16]] =
  stderr.writeLine("TUCK PENDING: readSensor invoked (not implemented)")

proc fetchFeed*[T](payload: T): TuckResult[tuple[feed: tuckˑtypeˑFeed]] =
  stderr.writeLine("TUCK PENDING: fetchFeed invoked (not implemented)")



