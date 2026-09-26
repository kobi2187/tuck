#+feature dynamic-literals
package main

tuck_type_ServerConfig :: struct {
	port: int,
	timeout: u32,
	running: bool,
}

tuck_fn_withDefaults :: proc (self: tuck_type_ServerConfig) -> tuck_type_ServerConfig {
  return tuck_type_ServerConfig{port = 80, timeout = u32(30), running = false}
}

tuck_fn_start :: proc (self: tuck_type_ServerConfig) -> bool {
  return true
}

tuck_fn_main :: proc () {
  tuck_server := tuck_type_ServerConfig{port = 0, timeout = u32(0), running = false}
  tuck_server = tuck_type_ServerConfig{port = 80, timeout = u32(30), running = false}
  tuck_server.port = 8080
  tuck_server.timeout = 60
  tuck_ok := tuck_fn_start(tuck_server)
  return
}

main :: proc() {
	tuck_fn_main()
}
