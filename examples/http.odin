#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_body :: struct ($T_body: typeid) {
	body: T_body,
}

tuck_HttpError :: enum { Unreachable, BadStatus }

tuck_get :: proc(payload: $T) -> rt.TuckResult(TRec_body(string)) {
	fmt.println("TUCK PENDING: tuck_get invoked (not implemented)")
	return {}
}


main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
