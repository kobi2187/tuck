#+feature dynamic-literals
package main

import rt "./tuckrt"

tuckG_0_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_0_drop :: proc(value: $G) {
	delete(value)
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


TRec_title_duration_playSpeed_volume_speed :: struct ($T_title: typeid, $T_duration: typeid, $T_playSpeed: typeid, $T_volume: typeid, $T_speed: typeid) {
	title: T_title,
	duration: T_duration,
	playSpeed: T_playSpeed,
	volume: T_volume,
	speed: T_speed,
}

tuckˑtypeˑEpisode :: struct {
	title: string,
	duration: u32,
	playSpeed: f64,
}

tuckˑtypeˑPlayerPrefs :: struct {
	volume: int,
	speed: f64,
}

tuckˑfnˑdescribe :: proc (title: string, volume: int) -> string {
  title := title
  return title
}

tuckˑfnˑheader :: proc (episode: tuckˑtypeˑEpisode, n: int) -> string {
  return tuckG_0_copy(episode.title)
}

tuckˑfnˑplay :: proc (episode: tuckˑtypeˑEpisode, prefs: tuckˑtypeˑPlayerPrefs) -> string {
  episode := episode
  tuckˑvˑctx := TRec_title_duration_playSpeed_volume_speed(string, u32, f64, int, f64){title = episode.title, duration = u32(episode.duration), playSpeed = episode.playSpeed, volume = prefs.volume, speed = prefs.speed}
  return tuckˑfnˑdescribe(tuckˑvˑctx.title, tuckˑvˑctx.volume)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckTrackCheck()
}
