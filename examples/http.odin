#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_body :: struct ($T_body: typeid) {
	body: T_body,
}

tuckˑtypeˑHttpError :: enum { Unreachable, BadStatus }

tuckˑfnˑget :: proc(payload: $T) -> rt.TuckResult(TRec_body(string)) {
	fmt.println("TUCK PENDING: get invoked (not implemented)")
	return {}
}


main :: proc() {
}
