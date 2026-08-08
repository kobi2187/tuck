package main

import "core:fmt"
import time "./mod_time"

TRec_hasNew_episodes_metadata_7970 :: struct {
	hasNew: bool,
	episodes: int,
	metadata: string,
}

TRec_episodes_BAA2 :: struct {
	episodes: int,
}

TRec_url_timeout_E49C :: struct {
	url: string,
	timeout: time.tuck_Milliseconds,
}

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

tuck_fetch :: proc(payload: $T) -> TRec_hasNew_episodes_metadata_7970 {
	fmt.println("TUCK PENDING: tuck_fetch invoked (not implemented)")
	return {}
}

tuck_parse :: proc(payload: $T) -> TRec_episodes_BAA2 {
	fmt.println("TUCK PENDING: tuck_parse invoked (not implemented)")
	return {}
}

tuck_selectEpisodes :: proc(payload: $T) -> TRec_episodes_BAA2 {
	fmt.println("TUCK PENDING: tuck_selectEpisodes invoked (not implemented)")
	return {}
}

tuck_process :: proc(payload: $T) {
	fmt.println("TUCK PENDING: tuck_process invoked (not implemented)")
}

tuck_log :: proc(payload: $T) {
	fmt.println("TUCK PENDING: tuck_log invoked (not implemented)")
}

tuck_playTrack :: proc(payload: $T) {
	fmt.println("TUCK PENDING: tuck_playTrack invoked (not implemented)")
}


tuck_main :: proc () {
  request := TRec_url_timeout_E49C{url = "example.com", timeout = time.tuck_ms(5)}
  response := tuck_selectEpisodes(tuck_parse(tuck_fetch(request)))
  feed := tuck_fetch("https://example.com/feed")
  if feed.hasNew {
      tuck_process(feed.episodes)
  } else {
      tuck_log(feed.metadata)
  }
  externalTrack := TRec_trackId_title_durationMs_80A6{trackId = 101, title = "Deep Dive", durationMs = 212000}
  normalizedTrack := TRec_id_name_length_19B2{id = externalTrack.trackId, name = externalTrack.title, length = externalTrack.durationMs}
  tuck_playTrack(normalizedTrack)
  return
}

main :: proc() {
	tuck_main()
}
