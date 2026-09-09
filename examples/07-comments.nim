{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_main*(): void

type tuck_LightState* = enum Off, On
proc canTransition*(frm, to: tuck_LightState): bool =
  case frm
  of Off: to in {On}
  of On: to in {Off}
proc transitionTo*(self: var tuck_LightState, target: tuck_LightState) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

proc tuck_fetch*[T](payload: T): tuple[status: int] =
  stderr.writeLine("TUCK PENDING: tuck_fetch invoked (not implemented)")


proc tuck_main*(): void =
  var tuck_config = (url: "https://api.example.com", timeout: 100)
  var tuck_result = tuck_fetch(tuck_config)
  return

