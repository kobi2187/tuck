#+feature dynamic-literals
package main

tuck_ServerConfig :: struct {
	port: int,
	timeout: u32,
	running: bool,
}

tuck_withDefaults :: proc (self: tuck_ServerConfig) -> tuck_ServerConfig {
  return tuck_ServerConfig{port = 80, timeout = u32(30), running = false}
}

tuck_start :: proc (self: tuck_ServerConfig) -> bool {
  return true
}

tuck_main :: proc () {
  tuck_server := tuck_ServerConfig{port = 0, timeout = u32(0), running = false}
  tuck_server = tuck_ServerConfig{port = 80, timeout = u32(30), running = false}
  tuck_server.port = 8080
  tuck_server.timeout = 60
  tuck_ok := tuck_start(tuck_server)
  return
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
