{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.}
proc tuckDrop*(x: var tuckˑtypeˑPodcastPlayerLifecycle)

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

type
  tuckˑtypeˑPodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready, Error
  tuckˑtypeˑPodcastPlayerLifecycle_Unloaded* = object
    config*: tuckˑtypeˑConfig
  tuckˑtypeˑPodcastPlayerLifecycle_Loading* = object
    config*: tuckˑtypeˑConfig
    progress*: int
  tuckˑtypeˑPodcastPlayerLifecycle_Ready* = object
    config*: tuckˑtypeˑConfig
    feed*: tuckˑtypeˑFeed
    audio*: tuckˑtypeˑAudioPlayer
  tuckˑtypeˑPodcastPlayerLifecycle_Error* = object
    config*: tuckˑtypeˑConfig
    reason*: string
  tuckˑtypeˑPodcastPlayerLifecycle* = object
    case kind*: tuckˑtypeˑPodcastPlayerLifecycleKind
    of Unloaded: tuckˑvariantˑunloaded*: tuckˑtypeˑPodcastPlayerLifecycle_Unloaded
    of Loading: tuckˑvariantˑloading*: tuckˑtypeˑPodcastPlayerLifecycle_Loading
    of Ready: tuckˑvariantˑready*: tuckˑtypeˑPodcastPlayerLifecycle_Ready
    of Error: tuckˑvariantˑerror*: tuckˑtypeˑPodcastPlayerLifecycle_Error

proc `==`*(a, b: tuckˑtypeˑPodcastPlayerLifecycle): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuckˑvariantˑunloaded == b.tuckˑvariantˑunloaded
  of Loading: a.tuckˑvariantˑloading == b.tuckˑvariantˑloading
  of Ready: a.tuckˑvariantˑready == b.tuckˑvariantˑready
  of Error: a.tuckˑvariantˑerror == b.tuckˑvariantˑerror

proc tuckDrop*(x: var tuckˑtypeˑPodcastPlayerLifecycle) =
  case x.kind
  of Unloaded: tuckDrop(x.tuckˑvariantˑunloaded)
  of Loading: tuckDrop(x.tuckˑvariantˑloading)
  of Ready: tuckDrop(x.tuckˑvariantˑready)
  of Error: tuckDrop(x.tuckˑvariantˑerror)

type tuckˑobjectˑPodcastApp* = object
  volume*: int
  timeout*: uint32

# interface Storable: no satisfying types

proc tuckˑfnˑloadEpisode*(self: tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode): tuckˑobjectˑPodcastApp =
  return self

proc tuckˑfnˑstartAudio*(self: tuckˑobjectˑPodcastApp): void =
  return

proc tuckˑobjectˑPodcastAppˑsetMany*(self: tuckˑobjectˑPodcastApp, pairs: seq[tuckˑtypeˑPair]): TuckResult[tuple[]] =
  discard

proc tuckˑobjectˑPodcastAppˑplay*(self: var tuckˑobjectˑPodcastApp, episode: tuckˑtypeˑEpisode): void =
  var tuckChain1 = self
  tuckChain1 = tuckˑfnˑloadEpisode(tuckChain1, episode)
  tuckˑfnˑstartAudio(tuckChain1)


