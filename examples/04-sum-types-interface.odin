#+feature dynamic-literals
package main

import rt "./tuckrt"

tuck_type_Config :: struct {
	url: string,
}

tuck_type_Feed :: struct {
	title: string,
}

tuck_type_AudioPlayer :: struct {
	volume: int,
}

tuck_type_NetworkClient :: struct {
	timeout: u32,
}

tuck_type_Episode :: struct {
	name: string,
}

tuck_type_Pair :: struct {
	key: string,
	val: string,
}

tuck_type_PodcastPlayerLifecycle_Unloaded :: struct {
	config: tuck_type_Config,
}
tuck_type_PodcastPlayerLifecycle_Loading :: struct {
	config: tuck_type_Config,
	progress: int,
}
tuck_type_PodcastPlayerLifecycle_Ready :: struct {
	config: tuck_type_Config,
	feed: tuck_type_Feed,
	audio: tuck_type_AudioPlayer,
}
tuck_type_PodcastPlayerLifecycle_Error :: struct {
	config: tuck_type_Config,
	reason: string,
}
tuck_type_PodcastPlayerLifecycle :: union {tuck_type_PodcastPlayerLifecycle_Unloaded, tuck_type_PodcastPlayerLifecycle_Loading, tuck_type_PodcastPlayerLifecycle_Ready, tuck_type_PodcastPlayerLifecycle_Error}

tuck_type_PodcastPlayerLifecycle_eq :: proc(a, b: tuck_type_PodcastPlayerLifecycle) -> bool {
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Unloaded); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Unloaded)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    return true
  }
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Loading); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Loading)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.progress != bv.progress { return false }
    return true
  }
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Ready); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Ready)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.feed != bv.feed { return false }
    if av.audio != bv.audio { return false }
    return true
  }
  if av, aok := a.(tuck_type_PodcastPlayerLifecycle_Error); aok {
    _ = av
    bv, bok := b.(tuck_type_PodcastPlayerLifecycle_Error)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.reason != bv.reason { return false }
    return true
  }
  return false
}

// interface Storable: no satisfying types

tuck_fn_loadEpisode :: proc (self: tuck_type_PodcastApp, episode: tuck_type_Episode) -> tuck_type_PodcastApp {
  return self
}

tuck_fn_startAudio :: proc (self: tuck_type_PodcastApp) {
  return
}

tuck_type_PodcastApp :: struct {
	volume: int,
	timeout: u32,
}

tuck_type_PodcastApp_tuck_fn_setMany :: proc (self: ^tuck_type_PodcastApp, pairs: [dynamic]tuck_type_Pair) -> rt.TuckResult(rt.TuckUnit) {

  return {}
}

tuck_type_PodcastApp_play :: proc (self: ^tuck_type_PodcastApp, episode: tuck_type_Episode) {
  tuckChain1 := self^
  tuckChain1 = tuck_fn_loadEpisode(tuckChain1, episode)
  tuck_fn_startAudio(tuckChain1)
}


main :: proc() {
}
