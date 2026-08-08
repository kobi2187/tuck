import ../compiler/tuck_rt

type tuck_AppEventsKind* = enum SensorFailure, LowMemory
type tuck_AppEvents* = ref object
    kind*: tuck_AppEventsKind
    port*: uint8
    reason*: string
    remaining*: uint32

var latesttuck_AppEvents*: tuck_AppEvents

proc tuck_AppEvents_SensorFailure*(port: uint8, reason: string): void
proc raise_tuck_AppEvents_SensorFailure*(port: uint8, reason: string) =
  latesttuck_AppEvents = tuck_AppEvents(kind: SensorFailure, port: port, reason: reason)
  tuck_AppEvents_SensorFailure(port, reason)

proc raise_tuck_AppEvents_LowMemory*(remaining: uint32) =
  latesttuck_AppEvents = tuck_AppEvents(kind: LowMemory, remaining: remaining)
  discard


proc tuck_triggerEvent*(): void =
  raise_tuck_AppEvents_SensorFailure(1, "timeout")

proc tuck_AppEvents_SensorFailure*(port: uint8, reason: string): void =
  var x = port
  var y = reason

static: assert((1 == 1))
