#+feature dynamic-literals
package main

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

tuck_playTrack :: proc (id: int, name: string, length: int) {

}

tuck_main :: proc () {
  tuck_externalTrack := TRec_trackId_title_durationMs(int, string, int){trackId = 42, title = "Slow Jam", durationMs = 215000}
  tuck_playerInput := TRec_id_name_length(int, string, int){id = tuck_externalTrack.trackId, name = tuck_externalTrack.title, length = tuck_externalTrack.durationMs}
  tuck_playTrack(tuck_playerInput.id, tuck_playerInput.name, tuck_playerInput.length)
  return
}

main :: proc() {
	tuck_main()
}
