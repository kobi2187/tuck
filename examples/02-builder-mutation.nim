{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑwithDefaults*(self: tuckˑtypeˑServerConfig): tuckˑtypeˑServerConfig
proc tuckˑfnˑstart*(self: tuckˑtypeˑServerConfig): bool
proc tuckˑfnˑmain*(): void

type tuckˑtypeˑServerConfig* = object
  port*: int
  timeout*: uint32
  running*: bool

proc tuckˑfnˑwithDefaults*(self: tuckˑtypeˑServerConfig): tuckˑtypeˑServerConfig =
  return tuckˑtypeˑServerConfig(port: 80, timeout: 30'u32, running: false)

proc tuckˑfnˑstart*(self: tuckˑtypeˑServerConfig): bool =
  return true

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑserver = tuckˑtypeˑServerConfig(port: 0, timeout: 0'u32, running: false)
  tuckˑvˑserver = tuckˑtypeˑServerConfig(port: 80, timeout: 30'u32, running: false)
  tuckˑvˑserver.port = 8080
  tuckˑvˑserver.timeout = 60
  var tuckˑvˑok = tuckˑfnˑstart(tuckˑvˑserver)
  return

