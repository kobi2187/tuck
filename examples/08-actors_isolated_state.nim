{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuckˑactorˑTrafficLightStateKind* = enum Red, Yellow, Green

type tuckˑactorˑTrafficLightMsgKind* = enum msgNext
type tuckˑactorˑTrafficLightMsg* = object
  tuckTag*: tuckˑactorˑTrafficLightMsgKind

type tuckˑactorˑTrafficLight* = ref object
  state*: tuckˑactorˑTrafficLightStateKind
  mailbox*: Mailbox[tuckˑactorˑTrafficLightMsg, 4]

let tuckˑactorˑTrafficLightSingleton* = tuckˑactorˑTrafficLight(state: Red)

proc handleMsg*(self: tuckˑactorˑTrafficLight, msg: tuckˑactorˑTrafficLightMsg) =
  case msg.tuckTag
  of msgNext:
    if true:
      self.state = (case self.state
      of Red:
        Green
      of Green:
        Yellow
      of Yellow:
        Red)

proc draintuckˑactorˑTrafficLight(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑTrafficLightSingleton.mailbox):
      handleMsg(tuckˑactorˑTrafficLightSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑTrafficLightSlot*: pointer
proc registerActortuckˑactorˑTrafficLight*() =
  tuckˑactorˑTrafficLightSlot = tuckStartActor(draintuckˑactorˑTrafficLight)

