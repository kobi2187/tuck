#+feature dynamic-literals
package main

tuck_AppEventsKind :: enum { SensorFailure, LowMemory }
tuck_AppEvents :: struct {
	tuckTag: tuck_AppEventsKind,
	port: u8,
	reason: string,
	remaining: u32,
}

latesttuck_AppEvents: tuck_AppEvents

raise_tuck_AppEvents_SensorFailure :: proc(port: u8, reason: string) {
	latesttuck_AppEvents = tuck_AppEvents{tuckTag = .SensorFailure, port = port, reason = reason}
	tuck_fn_AppEvents_SensorFailure(port, reason)
}

raise_tuck_AppEvents_LowMemory :: proc(remaining: u32) {
	latesttuck_AppEvents = tuck_AppEvents{tuckTag = .LowMemory, remaining = remaining}
	tuck_fn_AppEvents_LowMemory(remaining)
}


tuck_fn_triggerEvent :: proc () {
  raise_tuck_AppEvents_SensorFailure(1, "timeout")
}

tuck_fn_AppEvents_SensorFailure :: proc (port: u8, reason: string) {
  tuck_x := port
  tuck_y := reason
}

tuck_fn_AppEvents_LowMemory :: proc (remaining: u32) {
  tuck_left := remaining
}

main :: proc() {
	assert((1 == 1))
}
