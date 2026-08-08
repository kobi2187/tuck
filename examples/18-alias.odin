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
  externalTrack := TRec_trackId_title_durationMs_80A6{trackId = 42, title = "Slow Jam", durationMs = 215000}
  playerInput := TRec_id_name_length_19B2{id = externalTrack.trackId, name = externalTrack.title, length = externalTrack.durationMs}
  tuck_playTrack(playerInput.id, playerInput.name, playerInput.length)
  return
}

main :: proc() {
	tuck_main()
}
