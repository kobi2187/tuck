import ../compiler/tuck_rt

type tuck_Config* = object
    url*: string

type tuck_Feed* = object
    title*: string

type tuck_AudioPlayer* = object
    volume*: int

type tuck_NetworkClient* = object
    timeout*: uint32

type tuck_Episode* = object
    name*: string

type tuck_Pair* = object
    key*: string
    val*: string

type tuck_PodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready, Error
type tuck_PodcastPlayerLifecycle* = object
  case kind*: tuck_PodcastPlayerLifecycleKind
  of Unloaded: unloaded*: tuple[config: tuck_Config]
  of Loading: loading*: tuple[config: tuck_Config, progress: int]
  of Ready: ready*: tuple[config: tuck_Config, feed: tuck_Feed, audio: tuck_AudioPlayer]
  of Error: error*: tuple[config: tuck_Config, reason: string]

type tuck_PodcastApp* = object
    volume*: int
    timeout*: uint32

# interface Storable: no satisfying types

proc tuck_loadEpisode*(self: var tuck_PodcastApp, episode: var tuck_Episode): tuck_PodcastApp =
  return self

proc tuck_startAudio*(self: var tuck_PodcastApp): void =
  return

proc tuck_setMany*(self: var tuck_PodcastApp, pairs: seq[tuck_Pair]): TuckResult[tuple[]] =
  discard

proc play*(self: var tuck_PodcastApp, episode: var tuck_Episode): void =
  var tuckChain1 = self
  tuckChain1 = tuck_loadEpisode(tuckChain1, episode)
  tuck_startAudio(tuckChain1)


