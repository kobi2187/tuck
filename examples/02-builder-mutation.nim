{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_withDefaults*(self: tuck_type_ServerConfig): tuck_type_ServerConfig
proc tuck_fn_start*(self: tuck_type_ServerConfig): bool
proc tuck_fn_main*(): void

type tuck_type_ServerConfig* = object
  port*: int
  timeout*: uint32
  running*: bool

proc tuck_fn_withDefaults*(self: tuck_type_ServerConfig): tuck_type_ServerConfig =
  return tuck_type_ServerConfig(port: 80, timeout: 30'u32, running: false)

proc tuck_fn_start*(self: tuck_type_ServerConfig): bool =
  return true

proc tuck_fn_main*(): void =
  var tuck_server = tuck_type_ServerConfig(port: 0, timeout: 0'u32, running: false)
  tuck_server = tuck_type_ServerConfig(port: 80, timeout: 30'u32, running: false)
  tuck_server.port = 8080
  tuck_server.timeout = 60
  var tuck_ok = tuck_fn_start(tuck_server)
  return

