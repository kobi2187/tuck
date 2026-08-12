package main

tuck_AppEventsKind :: enum { SensorFailure, LowMemory }
tuck_AppEvents :: struct {
	kind: tuck_AppEventsKind,
	port: u8,
	reason: string,
	remaining: u32,
}

latesttuck_AppEvents: tuck_AppEvents

raise_tuck_AppEvents_SensorFailure :: proc(port: u8, reason: string) {
	latesttuck_AppEvents = tuck_AppEvents{kind = .SensorFailure, port = port, reason = reason}
	tuck_AppEvents_SensorFailure(port, reason)
}

raise_tuck_AppEvents_LowMemory :: proc(remaining: u32) {
	latesttuck_AppEvents = tuck_AppEvents{kind = .LowMemory, remaining = remaining}
	tuck_AppEvents_LowMemory(remaining)
}


tuck_triggerEvent :: proc () {
  raise_tuck_AppEvents_SensorFailure(1, "timeout")
}

tuck_AppEvents_SensorFailure :: proc (port: u8, reason: string) {
  x := port
  y := reason
}

tuck_AppEvents_LowMemory :: proc (remaining: u32) {
  left := remaining
}

main :: proc() {
	assert((1 == 1))
}
