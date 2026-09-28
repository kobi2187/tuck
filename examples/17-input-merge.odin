#+feature dynamic-literals
package main

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
  return title
}

tuckˑfnˑheader :: proc (episode: tuckˑtypeˑEpisode, n: int) -> string {
  return episode.title
}

tuckˑfnˑplay :: proc (episode: tuckˑtypeˑEpisode, prefs: tuckˑtypeˑPlayerPrefs) -> string {
  tuckˑvˑctx := TRec_title_duration_playSpeed_volume_speed(string, u32, f64, int, f64){title = episode.title, duration = episode.duration, playSpeed = episode.playSpeed, volume = prefs.volume, speed = prefs.speed}
  return tuckˑfnˑdescribe(tuckˑvˑctx.title, tuckˑvˑctx.volume)
}

main :: proc() {
}
