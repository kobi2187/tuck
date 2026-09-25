{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_TrafficLightStateKind* = enum Red, Yellow, Green

type tuck_TrafficLightMsgKind* = enum msgNext
type tuck_TrafficLightMsg* = object
  tuckTag*: tuck_TrafficLightMsgKind

type tuck_TrafficLight* = ref object
  state*: tuck_TrafficLightStateKind
  mailbox*: Mailbox[tuck_TrafficLightMsg, 4]

let tuck_TrafficLightSingleton* = tuck_TrafficLight(state: Red)

proc handleMsg*(self: tuck_TrafficLight, msg: tuck_TrafficLightMsg) =
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

proc draintuck_TrafficLight(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_TrafficLightSingleton.mailbox):
      handleMsg(tuck_TrafficLightSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_TrafficLightSlot*: pointer
proc registerActortuck_TrafficLight*() =
  tuck_TrafficLightSlot = tuckStartActor(draintuck_TrafficLight)

