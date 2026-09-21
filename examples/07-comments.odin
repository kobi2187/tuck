#+feature dynamic-literals
package main

import "core:fmt"

TRec_status :: struct ($T_status: typeid) {
	status: T_status,
}

TRec_url_timeout :: struct ($T_url: typeid, $T_timeout: typeid) {
	url: T_url,
	timeout: T_timeout,
}

tuck_fetch :: proc(payload: $T) -> TRec_status(int) {
	fmt.println("TUCK PENDING: tuck_fetch invoked (not implemented)")
	return {}
}


tuck_main :: proc () {
  tuck_config := TRec_url_timeout(string, int){url = "https://api.example.com", timeout = 100}
  tuck_result := tuck_fetch(tuck_config)
  return
}

tuck_LightState :: enum { Off, On }
canTransition_tuck_LightState :: proc(frm: tuck_LightState, to: tuck_LightState) -> bool {
	switch frm {
	case .Off: return to == .On
	case .On: return to == .Off
	}
	return false
}
transitionTo_tuck_LightState :: proc(self: ^tuck_LightState, target: tuck_LightState) {
	assert(canTransition_tuck_LightState(self^, target), "Invalid transition")
	self^ = target
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
