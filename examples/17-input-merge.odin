#+feature dynamic-literals
package main

TRec_title_duration_playSpeed_volume_speed :: struct ($T_title: typeid, $T_duration: typeid, $T_playSpeed: typeid, $T_volume: typeid, $T_speed: typeid) {
	title: T_title,
	duration: T_duration,
	playSpeed: T_playSpeed,
	volume: T_volume,
	speed: T_speed,
}

tuck_type_Episode :: struct {
	title: string,
	duration: u32,
	playSpeed: f64,
}

tuck_type_PlayerPrefs :: struct {
	volume: int,
	speed: f64,
}

tuck_fn_describe :: proc (title: string, volume: int) -> string {
  return title
}

tuck_fn_header :: proc (episode: tuck_type_Episode, n: int) -> string {
  return episode.title
}

tuck_fn_play :: proc (episode: tuck_type_Episode, prefs: tuck_type_PlayerPrefs) -> string {
  tuck_ctx := TRec_title_duration_playSpeed_volume_speed(string, u32, f64, int, f64){title = episode.title, duration = episode.duration, playSpeed = episode.playSpeed, volume = prefs.volume, speed = prefs.speed}
  return tuck_fn_describe(tuck_ctx.title, tuck_ctx.volume)
}

main :: proc() {
}
