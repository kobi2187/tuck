#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_status :: struct ($T_status: typeid) {
	status: T_status,
}

TRec_url_timeout :: struct ($T_url: typeid, $T_timeout: typeid) {
	url: T_url,
	timeout: T_timeout,
}

tuckˑfnˑfetch :: proc(p0: $T0) -> TRec_status(int) {
	fmt.println("TUCK PENDING: fetch invoked (not implemented)")
	return {}
}


tuckˑfnˑmain :: proc () {
  tuckˑvˑconfig := TRec_url_timeout(string, int){url = rt.tuckStrOwned("https://api.example.com"), timeout = 100}
  defer rt.tuckDrop(tuckˑvˑconfig.url)
  tuckˑvˑresult := tuckˑfnˑfetch(tuckˑvˑconfig.url)
  return
}

tuckˑtypeˑLightState :: enum { Off, On }
canTransition_tuckˑtypeˑLightState :: proc(frm: tuckˑtypeˑLightState, to: tuckˑtypeˑLightState) -> bool {
	switch frm {
	case .Off: return to == .On
	case .On: return to == .Off
	}
	return false
}
transitionTo_tuckˑtypeˑLightState :: proc(self: ^tuckˑtypeˑLightState, target: tuckˑtypeˑLightState) {
	assert(canTransition_tuckˑtypeˑLightState(self^, target), "Invalid transition")
	self^ = target
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
