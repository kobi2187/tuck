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
  var server = tuck_ServerConfig(port: 0, timeout: 0, running: false)
  server = tuck_withDefaults(server)
  server.port = 8080
  server.timeout = 60
  var ok = tuck_start(server)
  return

