{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑLightState* = enum Off, On
proc canTransition*(frm, to: tuckˑtypeˑLightState): bool =
  case frm
  of Off: to in {On}
  of On: to in {Off}
proc transitionTo*(self: var tuckˑtypeˑLightState, target: tuckˑtypeˑLightState) =
  if not canTransition(self, target):
    raise newException(ValueError, "Invalid transition " & $self & " -> " & $target)
  self = target

proc tuckˑfnˑfetch*[T0](p0: T0): tuple[status: int] =
  stderr.writeLine("TUCK PENDING: fetch invoked (not implemented)")


proc tuckˑfnˑmain*(): void =
  var tuckˑvˑconfig = (url: tuckCopy("https://api.example.com"), timeout: 100)
  defer: tuckDrop(tuckˑvˑconfig.url)
  var tuckˑvˑresult = tuckˑfnˑfetch(tuckˑvˑconfig.url)
  return

