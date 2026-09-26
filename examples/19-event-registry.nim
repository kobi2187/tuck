{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑtriggerEvent*(): void
proc tuckˑfnˑAppEvents_SensorFailure*(port: uint8, reason: sink string): void
proc tuckˑfnˑAppEvents_LowMemory*(remaining: uint32): void

type tuckˑregistryˑAppEventsKind* = enum SensorFailure, LowMemory
type tuckˑregistryˑAppEvents* = ref object
  tuckTag*: tuckˑregistryˑAppEventsKind
  port*: uint8
  reason*: string
  remaining*: uint32

var latesttuckˑregistryˑAppEvents*: tuckˑregistryˑAppEvents

proc raise_tuckˑregistryˑAppEvents_SensorFailure*(port: uint8, reason: string) =
  latesttuckˑregistryˑAppEvents = tuckˑregistryˑAppEvents(tuckTag: SensorFailure, port: port, reason: reason)
  tuckˑfnˑAppEvents_SensorFailure(port, reason)

proc raise_tuckˑregistryˑAppEvents_LowMemory*(remaining: uint32) =
  latesttuckˑregistryˑAppEvents = tuckˑregistryˑAppEvents(tuckTag: LowMemory, remaining: remaining)
  tuckˑfnˑAppEvents_LowMemory(remaining)


proc tuckˑfnˑtriggerEvent*(): void =
  raise_tuckˑregistryˑAppEvents_SensorFailure(1, "timeout")

proc tuckˑfnˑAppEvents_SensorFailure*(port: uint8, reason: sink string): void =
  var tuckˑvˑx = port
  var tuckˑvˑy = reason

proc tuckˑfnˑAppEvents_LowMemory*(remaining: uint32): void =
  var tuckˑvˑleft = remaining

static: assert((1 == 1))
