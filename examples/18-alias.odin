#+feature dynamic-literals
package main

TRec_trackId_title_durationMs_80A6 :: struct {
	trackId: int,
	title: string,
	durationMs: int,
}

TRec_id_name_length_19B2 :: struct {
	id: int,
	name: string,
	length: int,
}

tuck_playTrack :: proc (id: int, name: string, length: int) {

}

tuck_main :: proc () {
  tuck_externalTrack := TRec_trackId_title_durationMs_80A6{trackId = 42, title = "Slow Jam", durationMs = 215000}
  tuck_playerInput := TRec_id_name_length_19B2{id = tuck_externalTrack.trackId, name = tuck_externalTrack.title, length = tuck_externalTrack.durationMs}
  tuck_playTrack(tuck_playerInput.id, tuck_playerInput.name, tuck_playerInput.length)
  return
}

main :: proc() {
	tuck_main()
}
