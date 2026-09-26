{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.}

proc tuckˑfnˑloadEpisode*(self: tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode): tuckˑobjectˑPodcastApp
proc tuckˑfnˑstartAudio*(self: tuckˑobjectˑPodcastApp): void

type tuckˑtypeˑConfig* = object
  url*: string

type tuckˑtypeˑFeed* = object
  title*: string

type tuckˑtypeˑAudioPlayer* = object
  volume*: int

type tuckˑtypeˑNetworkClient* = object
  timeout*: uint32

type tuckˑtypeˑEpisode* = object
  name*: string

type tuckˑtypeˑPair* = object
  key*: string
  val*: string

type tuckˑtypeˑPodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready, Error
type tuckˑtypeˑPodcastPlayerLifecycle* = object
  case kind*: tuckˑtypeˑPodcastPlayerLifecycleKind
  of Unloaded: tuckˑvariantˑunloaded*: tuple[config: tuckˑtypeˑConfig]
  of Loading: tuckˑvariantˑloading*: tuple[config: tuckˑtypeˑConfig, progress: int]
  of Ready: tuckˑvariantˑready*: tuple[config: tuckˑtypeˑConfig, feed: tuckˑtypeˑFeed, audio: tuckˑtypeˑAudioPlayer]
  of Error: tuckˑvariantˑerror*: tuple[config: tuckˑtypeˑConfig, reason: string]

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuckˑvariantˑunloaded == b.tuckˑvariantˑunloaded
  of Loading: a.tuckˑvariantˑloading == b.tuckˑvariantˑloading
  of Ready: a.tuckˑvariantˑready == b.tuckˑvariantˑready
  of Error: a.tuckˑvariantˑerror == b.tuckˑvariantˑerror

type tuckˑobjectˑPodcastApp* = object
  volume*: int
  timeout*: uint32

# interface Storable: no satisfying types

proc tuckˑfnˑloadEpisode*(self: tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode): tuckˑobjectˑPodcastApp =
  return self

proc tuckˑfnˑstartAudio*(self: tuckˑobjectˑPodcastApp): void =
  return

proc tuckˑobjectˑPodcastApp_tuckˑfnˑsetMany*(self: var tuckˑobjectˑPodcastApp, pairs: seq[tuckˑtypeˑPair]): TuckResult[tuple[]] =
  discard

proc tuckˑobjectˑPodcastApp_play*(self: var tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode): void =
  var tuckChain1 = self
  tuckChain1 = tuckˑfnˑloadEpisode(tuckChain1, episode)
  tuckˑfnˑstartAudio(tuckChain1)


