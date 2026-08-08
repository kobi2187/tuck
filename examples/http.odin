package main

import "core:fmt"
import rt "./tuckrt"

TRec_body_12C4 :: struct {
	body: string,
}

tuck_get :: proc(payload: $T) -> rt.TuckResult(TRec_body_12C4) {
	fmt.println("TUCK PENDING: tuck_get invoked (not implemented)")
	return {}
}


main :: proc() {
}
