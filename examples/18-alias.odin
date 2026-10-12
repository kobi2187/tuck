#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"

TRec_trackId_title_durationMs :: struct ($T_trackId: typeid, $T_title: typeid, $T_durationMs: typeid) {
	trackId: T_trackId,
	title: T_title,
	durationMs: T_durationMs,
}

TRec_id_name_length :: struct ($T_id: typeid, $T_name: typeid, $T_length: typeid) {
	id: T_id,
	name: T_name,
	length: T_length,
}

tuckˑfnˑplayTrack :: proc(payload: $T) {
	fmt.println("TUCK PENDING: playTrack invoked (not implemented)")
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑexternalTrack := TRec_trackId_title_durationMs(int, string, int){trackId = 42, title = rt.tuckStrOwned("Slow Jam"), durationMs = 215000}
  tuckˑvˑplayerInput := TRec_id_name_length(int, string, int){id = tuckˑvˑexternalTrack.trackId, name = tuckˑvˑexternalTrack.title, length = tuckˑvˑexternalTrack.durationMs}
  defer rt.tuckDrop(tuckˑvˑplayerInput.name)
  tuckˑfnˑplayTrack(tuckˑvˑplayerInput)
  return
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
