{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_type_TrafficLightStateKind* = enum Red, Yellow, Green

type tuck_type_TrafficLightMsgKind* = enum msgNext
type tuck_type_TrafficLightMsg* = object
  tuckTag*: tuck_type_TrafficLightMsgKind

type tuck_type_TrafficLight* = ref object
  state*: tuck_type_TrafficLightStateKind
  mailbox*: Mailbox[tuck_type_TrafficLightMsg, 4]

let tuck_type_TrafficLightSingleton* = tuck_type_TrafficLight(state: Red)

proc handleMsg*(self: tuck_type_TrafficLight, msg: tuck_type_TrafficLightMsg) =
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

proc draintuck_type_TrafficLight(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_TrafficLightSingleton.mailbox):
      handleMsg(tuck_type_TrafficLightSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_TrafficLightSlot*: pointer
proc registerActortuck_type_TrafficLight*() =
  tuck_type_TrafficLightSlot = tuckStartActor(draintuck_type_TrafficLight)

