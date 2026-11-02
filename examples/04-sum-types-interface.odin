#+feature dynamic-literals
package main

import rt "./tuckrt"

tuckˑtypeˑConfig :: struct {
	url: string,
}

tuckˑtypeˑConfig_drop :: proc(x: tuckˑtypeˑConfig) {
  rt.tuckDrop(x.url)
}

tuckˑtypeˑFeed :: struct {
	title: string,
}

tuckˑtypeˑFeed_drop :: proc(x: tuckˑtypeˑFeed) {
  rt.tuckDrop(x.title)
}

tuckˑtypeˑAudioPlayer :: struct {
	volume: int,
}

tuckˑtypeˑNetworkClient :: struct {
	timeout: u32,
}

tuckˑtypeˑEpisode :: struct {
	name: string,
}

tuckˑtypeˑEpisode_drop :: proc(x: tuckˑtypeˑEpisode) {
  rt.tuckDrop(x.name)
}

tuckˑtypeˑPair :: struct {
	key: string,
	val: string,
}

tuckˑtypeˑPair_drop :: proc(x: tuckˑtypeˑPair) {
  rt.tuckDrop(x.key)
  rt.tuckDrop(x.val)
}

tuckˑtypeˑPodcastPlayerLifecycle_Unloaded :: struct {
	config: tuckˑtypeˑConfig,
}
tuckˑtypeˑPodcastPlayerLifecycle_Loading :: struct {
	config: tuckˑtypeˑConfig,
	progress: int,
}
tuckˑtypeˑPodcastPlayerLifecycle_Ready :: struct {
	config: tuckˑtypeˑConfig,
	feed: tuckˑtypeˑFeed,
	audio: tuckˑtypeˑAudioPlayer,
}
tuckˑtypeˑPodcastPlayerLifecycle_Error :: struct {
	config: tuckˑtypeˑConfig,
	reason: string,
}
tuckˑtypeˑPodcastPlayerLifecycle :: union {tuckˑtypeˑPodcastPlayerLifecycle_Unloaded, tuckˑtypeˑPodcastPlayerLifecycle_Loading, tuckˑtypeˑPodcastPlayerLifecycle_Ready, tuckˑtypeˑPodcastPlayerLifecycle_Error}

tuckˑtypeˑPodcastPlayerLifecycle_eq :: proc(a, b: tuckˑtypeˑPodcastPlayerLifecycle) -> bool {
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Unloaded); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Unloaded)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Loading); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Loading)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.progress != bv.progress { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Ready); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Ready)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.feed != bv.feed { return false }
    if av.audio != bv.audio { return false }
    return true
  }
  if av, aok := a.(tuckˑtypeˑPodcastPlayerLifecycle_Error); aok {
    _ = av
    bv, bok := b.(tuckˑtypeˑPodcastPlayerLifecycle_Error)
    _ = bv
    if !bok { return false }
    if av.config != bv.config { return false }
    if av.reason != bv.reason { return false }
    return true
  }
  return false
}

tuckˑtypeˑPodcastPlayerLifecycle_drop :: proc(x: tuckˑtypeˑPodcastPlayerLifecycle) {
  #partial switch v in x {
  case tuckˑtypeˑPodcastPlayerLifecycle_Unloaded:
    tuckˑtypeˑConfig_drop(v.config)
  case tuckˑtypeˑPodcastPlayerLifecycle_Loading:
    tuckˑtypeˑConfig_drop(v.config)
  case tuckˑtypeˑPodcastPlayerLifecycle_Ready:
    tuckˑtypeˑConfig_drop(v.config)
    tuckˑtypeˑFeed_drop(v.feed)
  case tuckˑtypeˑPodcastPlayerLifecycle_Error:
    tuckˑtypeˑConfig_drop(v.config)
    rt.tuckDrop(v.reason)
  }
}

// interface Storable: no satisfying types

tuckˑfnˑloadEpisode :: proc (self: tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode) -> tuckˑobjectˑPodcastApp {
  return self
}

tuckˑfnˑstartAudio :: proc (self: tuckˑobjectˑPodcastApp) {
  return
}

tuckˑobjectˑPodcastApp :: struct {
	volume: int,
	timeout: u32,
}

tuckˑobjectˑPodcastAppˑsetMany :: proc (self: tuckˑobjectˑPodcastApp, pairs: [dynamic]tuckˑtypeˑPair) -> rt.TuckResult(rt.TuckUnit) {

  return {}
}

tuckˑobjectˑPodcastAppˑplay :: proc (self: ^tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode) {
  tuckChain1 := self^
  tuckChain1 = tuckˑfnˑloadEpisode(tuckChain1, episode)
  tuckˑfnˑstartAudio(tuckChain1)
}


main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckTrackCheck()
}
