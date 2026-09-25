{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_main*(): void

type tuck_type_LightState* = enum Off, On
proc canTransition*(frm, to: tuck_type_LightState): bool =
  case frm
  of Off: to in {On}
  of On: to in {Off}
proc transitionTo*(self: var tuck_type_LightState, target: tuck_type_LightState) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

proc tuck_fn_fetch*[T](payload: T): tuple[status: int] =
  stderr.writeLine("TUCK PENDING: tuck_fn_fetch invoked (not implemented)")


proc tuck_fn_main*(): void =
  var tuck_config = (url: "https://api.example.com", timeout: 100)
  var tuck_result = tuck_fn_fetch(tuck_config)
  return

