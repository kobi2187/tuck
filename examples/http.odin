#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_body :: struct ($T_body: typeid) {
	body: T_body,
}

tuck_type_HttpError :: enum { Unreachable, BadStatus }

tuck_fn_get :: proc(payload: $T) -> rt.TuckResult(TRec_body(string)) {
	fmt.println("TUCK PENDING: tuck_fn_get invoked (not implemented)")
	return {}
}


main :: proc() {
}
