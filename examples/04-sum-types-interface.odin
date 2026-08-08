package main

import rt "./tuckrt"

tuck_Config :: struct {
	url: string,
}

tuck_Feed :: struct {
	title: string,
}

tuck_AudioPlayer :: struct {
	volume: int,
}

tuck_NetworkClient :: struct {
	timeout: u32,
}

tuck_Episode :: struct {
	name: string,
}

tuck_Pair :: struct {
	key: string,
	val: string,
}

tuck_PodcastPlayerLifecycle_Unloaded :: struct {
	config: tuck_Config,
}
tuck_PodcastPlayerLifecycle_Loading :: struct {
	config: tuck_Config,
	progress: int,
}
tuck_PodcastPlayerLifecycle_Ready :: struct {
	config: tuck_Config,
	feed: tuck_Feed,
	audio: tuck_AudioPlayer,
}
tuck_PodcastPlayerLifecycle_Error :: struct {
	config: tuck_Config,
	reason: string,
}
tuck_PodcastPlayerLifecycle :: union {tuck_PodcastPlayerLifecycle_Unloaded, tuck_PodcastPlayerLifecycle_Loading, tuck_PodcastPlayerLifecycle_Ready, tuck_PodcastPlayerLifecycle_Error}

// interface Storable: no satisfying types

tuck_loadEpisode :: proc (self: tuck_PodcastApp, episode: tuck_Episode) -> tuck_PodcastApp {
  return self
}

tuck_startAudio :: proc (self: tuck_PodcastApp) {
  return
}

tuck_PodcastApp :: struct {
	volume: int,
	timeout: u32,
}

tuck_PodcastApp_tuck_setMany :: proc (self: ^tuck_PodcastApp, pairs: [dynamic]tuck_Pair) -> rt.TuckResult(rt.TuckUnit) {

  return {}
}

tuck_PodcastApp_play :: proc (self: ^tuck_PodcastApp, episode: tuck_Episode) {
  self^ = tuck_loadEpisode(self^, episode)
  tuck_startAudio(self^)
}


main :: proc() {
}
