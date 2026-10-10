#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_trackId_title_durationMs :: struct ($T_trackId: typeid, $T_title: typeid, $T_durationMs: typeid) {
	trackId: T_trackId,
	title: T_title,
	durationMs: T_durationMs,
}

tuckG_0_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_0_drop :: proc(value: $G) {
	delete(value)
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


TRec_id_name_length :: struct ($T_id: typeid, $T_name: typeid, $T_length: typeid) {
	id: T_id,
	name: T_name,
	length: T_length,
}

tuckˑfnˑplayTrack :: proc(payload: $T) {
	fmt.println("TUCK PENDING: playTrack invoked (not implemented)")
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑexternalTrack := TRec_trackId_title_durationMs(int, string, int){trackId = 42, title = tuckG_0_copy("Slow Jam"), durationMs = 215000}
  tuckˑvˑplayerInput := TRec_id_name_length(int, string, int){id = tuckˑvˑexternalTrack.trackId, name = tuckˑvˑexternalTrack.title, length = tuckˑvˑexternalTrack.durationMs}
  defer tuckG_0_drop(tuckˑvˑplayerInput.name)
  tuckˑfnˑplayTrack(tuckˑvˑplayerInput)
  return
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
