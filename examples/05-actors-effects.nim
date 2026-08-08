import ../compiler/tuck_rt

type tuck_Feed* = object
  title*: string
  episodeCount*: int

type tuck_PodcastApp* = object
  discard

type tuck_CounterMsgKind* = enum msgIncrement, msgGet
type tuck_CounterMsg* = object
  kind*: tuck_CounterMsgKind
  n*: int

type tuck_Counter* = ref object
  count*: int
  mailbox*: Mailbox[tuck_CounterMsg, 8]

let tuck_CounterSingleton* = tuck_Counter()

proc handleMsg*(self: tuck_Counter, msg: tuck_CounterMsg) =
  case msg.kind
  of msgIncrement:
    let n = msg.n
    if true:
      self.count = (self.count + n)
  of msgGet:
    if true:
      var result = (count: self.count)

proc draintuck_Counter(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_CounterMsg
    while dequeue(tuck_CounterSingleton.mailbox, m):
      handleMsg(tuck_CounterSingleton, m)
      result = true

proc registerActortuck_Counter*() =
  tuckStartActor(draintuck_Counter)

proc tuck_readSensor*(port: uint8): TuckResult[tuple[value: uint16]] =
  discard

proc fetchFeed*[T](payload: T): TuckResult[tuple[feed: tuck_Feed]] =
  stderr.writeLine("TUCK PENDING: fetchFeed invoked (not implemented)")



