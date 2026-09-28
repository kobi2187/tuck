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

tuckˑfnˑfetch :: proc(payload: $T) -> TRec_hasNew_episodes_metadata(bool, int, string) {
	fmt.println("TUCK PENDING: fetch invoked (not implemented)")
	return {}
}

tuckˑfnˑparse :: proc(payload: $T) -> TRec_episodes(int) {
	fmt.println("TUCK PENDING: parse invoked (not implemented)")
	return {}
}

tuckˑfnˑselectEpisodes :: proc(payload: $T) -> TRec_episodes(int) {
	fmt.println("TUCK PENDING: selectEpisodes invoked (not implemented)")
	return {}
}

tuckˑfnˑprocess :: proc(payload: $T) {
	fmt.println("TUCK PENDING: process invoked (not implemented)")
}

tuckˑfnˑlog :: proc(payload: $T) {
	fmt.println("TUCK PENDING: log invoked (not implemented)")
}

tuckˑfnˑplayTrack :: proc(payload: $T) {
	fmt.println("TUCK PENDING: playTrack invoked (not implemented)")
}


tuckˑfnˑmain :: proc () {
  tuckˑvˑrequest := TRec_url_timeout(string, time.tuckˑtypeˑMilliseconds){url = "example.com", timeout = time.tuckˑfnˑms(u32(5))}
  tuckˑvˑresponse := tuckˑfnˑselectEpisodes(tuckˑfnˑparse(tuckˑfnˑfetch(tuckˑvˑrequest)))
  tuckˑvˑfeed := tuckˑfnˑfetch("https://example.com/feed")
  if tuckˑvˑfeed.hasNew {
      tuckˑfnˑprocess(tuckˑvˑfeed.episodes)
  } else {
      tuckˑfnˑlog(tuckˑvˑfeed.metadata)
  }
  tuckˑvˑexternalTrack := TRec_trackId_title_durationMs(int, string, int){trackId = 101, title = "Deep Dive", durationMs = 212000}
  tuckˑvˑnormalizedTrack := TRec_id_name_length(int, string, int){id = tuckˑvˑexternalTrack.trackId, name = tuckˑvˑexternalTrack.title, length = tuckˑvˑexternalTrack.durationMs}
  tuckˑfnˑplayTrack(tuckˑvˑnormalizedTrack)
  return
}

main :: proc() {
	tuckˑfnˑmain()
}
