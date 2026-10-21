#+feature dynamic-literals
package main

import rt "./tuckrt"

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
  raise_tuckˑregistryˑAppEvents_SensorFailure(u8(1), "timeout")
}

tuckˑfnˑAppEvents_SensorFailure :: proc (port: u8, reason: string) {
  tuckˑvˑx := port
  tuckˑvˑy := reason
  defer rt.tuckDrop(tuckˑvˑy)
}

tuckˑfnˑAppEvents_LowMemory :: proc (remaining: u32) {
  tuckˑvˑleft := remaining
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	assert((1 == 1))
	rt.tuckTrackCheck()
}
