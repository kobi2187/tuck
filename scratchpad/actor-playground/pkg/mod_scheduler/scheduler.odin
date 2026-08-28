package tuck_scheduler

import rt "../tuckrt"

tuck_Predicate :: proc () -> bool

waitUntil :: proc(pred: tuck_Predicate) {
	rt.waitUntil(pred)
}

stop :: proc() {
	rt.stop()
}


