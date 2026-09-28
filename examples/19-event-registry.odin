#+feature dynamic-literals
package main

tuckˑregistryˑAppEventsKind :: enum { SensorFailure, LowMemory }
tuckˑregistryˑAppEvents :: struct {
	tuckTag: tuckˑregistryˑAppEventsKind,
	port: u8,
	reason: string,
	remaining: u32,
}

latesttuckˑregistryˑAppEvents: tuckˑregistryˑAppEvents

raise_tuckˑregistryˑAppEvents_SensorFailure :: proc(port: u8, reason: string) {
	latesttuckˑregistryˑAppEvents = tuckˑregistryˑAppEvents{tuckTag = .SensorFailure, port = port, reason = reason}
	tuckˑfnˑAppEvents_SensorFailure(port, reason)
}

raise_tuckˑregistryˑAppEvents_LowMemory :: proc(remaining: u32) {
	latesttuckˑregistryˑAppEvents = tuckˑregistryˑAppEvents{tuckTag = .LowMemory, remaining = remaining}
	tuckˑfnˑAppEvents_LowMemory(remaining)
}


tuckˑfnˑtriggerEvent :: proc () {
  raise_tuckˑregistryˑAppEvents_SensorFailure(1, "timeout")
}

tuckˑfnˑAppEvents_SensorFailure :: proc (port: u8, reason: string) {
  tuckˑvˑx := port
  tuckˑvˑy := reason
}

tuckˑfnˑAppEvents_LowMemory :: proc (remaining: u32) {
  tuckˑvˑleft := remaining
}

main :: proc() {
	assert((1 == 1))
}
