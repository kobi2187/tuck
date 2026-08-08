package main

TRec_title_duration_playSpeed_volume_speed_F007 :: struct {
	title: string,
	duration: u32,
	playSpeed: f64,
	volume: int,
	speed: f64,
}

tuck_Episode :: struct {
	title: string,
	duration: u32,
	playSpeed: f64,
}

tuck_PlayerPrefs :: struct {
	volume: int,
	speed: f64,
}

tuck_describe :: proc (title: string, volume: int) -> string {
  return title
}

tuck_header :: proc (episode: tuck_Episode, n: int) -> string {
  return episode.title
}

tuck_play :: proc (episode: tuck_Episode, prefs: tuck_PlayerPrefs) -> string {
  ctx := TRec_title_duration_playSpeed_volume_speed_F007{title = episode.title, duration = episode.duration, playSpeed = episode.playSpeed, volume = prefs.volume, speed = prefs.speed}
  return tuck_describe(ctx.title, ctx.volume)
}

main :: proc() {
}
