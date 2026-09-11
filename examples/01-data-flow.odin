#+feature dynamic-literals
package main

import "core:fmt"
import time "./mod_time"

TRec_hasNew_episodes_metadata :: struct ($T_hasNew: typeid, $T_episodes: typeid, $T_metadata: typeid) {
	hasNew: T_hasNew,
	episodes: T_episodes,
	metadata: T_metadata,
}

TRec_episodes :: struct ($T_episodes: typeid) {
	episodes: T_episodes,
}

TRec_url_timeout :: struct ($T_url: typeid, $T_timeout: typeid) {
	url: T_url,
	timeout: T_timeout,
}

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

tuck_fetch :: proc(payload: $T) -> TRec_hasNew_episodes_metadata(bool, int, string) {
	fmt.println("TUCK PENDING: tuck_fetch invoked (not implemented)")
	return {}
}

tuck_parse :: proc(payload: $T) -> TRec_episodes(int) {
	fmt.println("TUCK PENDING: tuck_parse invoked (not implemented)")
	return {}
}

tuck_selectEpisodes :: proc(payload: $T) -> TRec_episodes(int) {
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
  tuck_request := TRec_url_timeout(string, time.tuck_Milliseconds){url = "example.com", timeout = time.tuck_ms(u32(5))}
  tuck_response := tuck_selectEpisodes(tuck_parse(tuck_fetch(tuck_request)))
  tuck_feed := tuck_fetch("https://example.com/feed")
  if tuck_feed.hasNew {
      tuck_process(tuck_feed.episodes)
  } else {
      tuck_log(tuck_feed.metadata)
  }
  tuck_externalTrack := TRec_trackId_title_durationMs(int, string, int){trackId = 101, title = "Deep Dive", durationMs = 212000}
  tuck_normalizedTrack := TRec_id_name_length(int, string, int){id = tuck_externalTrack.trackId, name = tuck_externalTrack.title, length = tuck_externalTrack.durationMs}
  tuck_playTrack(tuck_normalizedTrack)
  return
}

main :: proc() {
	tuck_main()
}
