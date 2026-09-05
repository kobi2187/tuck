{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_ServerConfig* = object
  port*: int
  timeout*: uint32
  running*: bool

proc tuck_withDefaults*(self: tuck_ServerConfig): tuck_ServerConfig =
  return tuck_ServerConfig(port: 80, timeout: 30, running: false)

proc tuck_start*(self: tuck_ServerConfig): bool =
  return true

proc tuck_main*(): void =
  var tuck_server = tuck_ServerConfig(port: 0, timeout: 0, running: false)
  tuck_server = tuck_ServerConfig(port: 80, timeout: 30, running: false)
  tuck_server.port = 8080
  tuck_server.timeout = 60
  var tuck_ok = tuck_start(tuck_server)
  return

