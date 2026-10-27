#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"
import tuckˑmodˑshapes_01_data_flow "./mod_shapes_01_data_flow"
import tuckˑmodˑtime "./mod_time"

tuckˑfnˑfetch :: proc(p0: $T0) -> tuckˑmodˑshapes_01_data_flow.TRec_hasNew_episodes_metadata(bool, int, string) {
	fmt.println("TUCK PENDING: fetch invoked (not implemented)")
	return {}
}

tuckˑfnˑparse :: proc(p0: $T0, p1: $T1, p2: $T2) -> tuckˑmodˑshapes_01_data_flow.TRec_episodes(int) {
	fmt.println("TUCK PENDING: parse invoked (not implemented)")
	return {}
}

tuckˑfnˑselectEpisodes :: proc(p0: $T0) -> tuckˑmodˑshapes_01_data_flow.TRec_episodes(int) {
	fmt.println("TUCK PENDING: selectEpisodes invoked (not implemented)")
	return {}
}

tuckˑfnˑprocess :: proc(p0: $T0) {
	fmt.println("TUCK PENDING: process invoked (not implemented)")
}

tuckˑfnˑlog :: proc(p0: $T0) {
	fmt.println("TUCK PENDING: log invoked (not implemented)")
}

tuckˑfnˑplayTrack :: proc(p0: $T0, p1: $T1, p2: $T2) {
	fmt.println("TUCK PENDING: playTrack invoked (not implemented)")
}


tuckˑfnˑmain :: proc () {
  tuckˑvˑrequest := tuckˑmodˑshapes_01_data_flow.TRec_url_timeout(string, tuckˑmodˑtime.tuckˑtypeˑMilliseconds){url = rt.tuckStrOwned("example.com"), timeout = tuckˑmodˑtime.tuckˑfnˑms(u32(5))}
  defer rt.tuckDrop(tuckˑvˑrequest.url)
  tuckOwnTmp1 := tuckˑfnˑfetch(tuckˑvˑrequest.url)
  defer rt.tuckDrop(tuckOwnTmp1.metadata)
  tuckˑvˑresponse := tuckˑfnˑselectEpisodes(tuckˑfnˑparse(tuckOwnTmp1.hasNew, tuckOwnTmp1.episodes, tuckOwnTmp1.metadata))
  tuckˑvˑfeed := tuckˑfnˑfetch("https://example.com/feed")
  defer rt.tuckDrop(tuckˑvˑfeed.metadata)
  if tuckˑvˑfeed.hasNew {
      tuckˑfnˑprocess(tuckˑvˑfeed.episodes)
  } else {
      tuckˑfnˑlog(tuckˑvˑfeed.metadata)
  }
  tuckˑvˑexternalTrack := tuckˑmodˑshapes_01_data_flow.TRec_trackId_title_durationMs(int, string, int){trackId = 101, title = rt.tuckStrOwned("Deep Dive"), durationMs = 212000}
  tuckˑvˑnormalizedTrack := tuckˑmodˑshapes_01_data_flow.TRec_id_name_length(int, string, int){id = tuckˑvˑexternalTrack.trackId, name = tuckˑvˑexternalTrack.title, length = tuckˑvˑexternalTrack.durationMs}
  defer rt.tuckDrop(tuckˑvˑnormalizedTrack.name)
  tuckˑfnˑplayTrack(tuckˑvˑnormalizedTrack.id, tuckˑvˑnormalizedTrack.name, tuckˑvˑnormalizedTrack.length)
  return
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
