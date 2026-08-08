import ../compiler/tuck_rt

type tuck_TrafficLightStateKind* = enum Red, Yellow, Green

type tuck_TrafficLightMsgKind* = enum msgNext
type tuck_TrafficLightMsg* = object
  kind*: tuck_TrafficLightMsgKind

type tuck_TrafficLight* = ref object
    state*: tuck_TrafficLightStateKind
    mailbox*: Mailbox[tuck_TrafficLightMsg, 4]

let tuck_TrafficLightSingleton* = tuck_TrafficLight()

proc handleMsg*(self: tuck_TrafficLight, msg: tuck_TrafficLightMsg) =
  case msg.kind
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
    var m: tuck_TrafficLightMsg
    while dequeue(tuck_TrafficLightSingleton.mailbox, m):
      handleMsg(tuck_TrafficLightSingleton, m)
      result = true

proc registerActortuck_TrafficLight*() =
  tuckStartActor(draintuck_TrafficLight)

