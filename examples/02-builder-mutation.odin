#+feature dynamic-literals
package main

tuckˑtypeˑServerConfig :: struct {
	port: int,
	timeout: u32,
	running: bool,
}

tuckˑfnˑwithDefaults :: proc (self: tuckˑtypeˑServerConfig) -> tuckˑtypeˑServerConfig {
  return tuckˑtypeˑServerConfig{port = 80, timeout = u32(30), running = false}
}

tuckˑfnˑstart :: proc (self: tuckˑtypeˑServerConfig) -> bool {
  return true
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑserver := tuckˑtypeˑServerConfig{port = 0, timeout = u32(0), running = false}
  tuckˑvˑserver = tuckˑtypeˑServerConfig{port = 80, timeout = u32(30), running = false}
  tuckˑvˑserver.port = 8080
  tuckˑvˑserver.timeout = 60
  tuckˑvˑok := tuckˑfnˑstart(tuckˑvˑserver)
  return
}

main :: proc() {
	tuckˑfnˑmain()
}
