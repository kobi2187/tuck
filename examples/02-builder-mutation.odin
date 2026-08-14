package main

tuck_ServerConfig :: struct {
	port: int,
	timeout: u32,
	running: bool,
}

tuck_withDefaults :: proc (self: tuck_ServerConfig) -> tuck_ServerConfig {
  return tuck_ServerConfig{port = 80, timeout = 30, running = false}
}

tuck_start :: proc (self: tuck_ServerConfig) -> bool {
  return true
}

tuck_main :: proc () {
  server := tuck_ServerConfig{port = 0, timeout = 0, running = false}
  server = tuck_ServerConfig{port = 80, timeout = 30, running = false}
  server.port = 8080
  server.timeout = 60
  ok := tuck_start(server)
  return
}

main :: proc() {
	tuck_main()
}
