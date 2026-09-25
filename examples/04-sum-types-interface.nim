{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc `==`*(a, b: tuck_type_PodcastPlayerLifecycle): bool {.noSideEffect.}

proc tuck_fn_loadEpisode*(self: tuck_type_PodcastApp, episode: tuck_type_Episode): tuck_type_PodcastApp
proc tuck_fn_startAudio*(self: tuck_type_PodcastApp): void

type tuck_type_Config* = object
  url*: string

type tuck_type_Feed* = object
  title*: string

type tuck_type_AudioPlayer* = object
  volume*: int

type tuck_type_NetworkClient* = object
  timeout*: uint32

type tuck_type_Episode* = object
  name*: string

type tuck_type_Pair* = object
  key*: string
  val*: string

type tuck_type_PodcastPlayerLifecycleKind* = enum Unloaded, Loading, Ready, Error
type tuck_type_PodcastPlayerLifecycle* = object
  case kind*: tuck_type_PodcastPlayerLifecycleKind
  of Unloaded: tuck_unloaded*: tuple[config: tuck_type_Config]
  of Loading: tuck_loading*: tuple[config: tuck_type_Config, progress: int]
  of Ready: tuck_ready*: tuple[config: tuck_type_Config, feed: tuck_type_Feed, audio: tuck_type_AudioPlayer]
  of Error: tuck_error*: tuple[config: tuck_type_Config, reason: string]

proc `==`*(a, b: tuck_type_PodcastPlayerLifecycle): bool {.noSideEffect.} =
  if a.kind != b.kind: return false
  case a.kind
  of Unloaded: a.tuck_unloaded == b.tuck_unloaded
  of Loading: a.tuck_loading == b.tuck_loading
  of Ready: a.tuck_ready == b.tuck_ready
  of Error: a.tuck_error == b.tuck_error

type tuck_type_PodcastApp* = object
  volume*: int
  timeout*: uint32

# interface Storable: no satisfying types

proc tuck_fn_loadEpisode*(self: tuck_type_PodcastApp, episode: tuck_type_Episode): tuck_type_PodcastApp =
  return self

proc tuck_fn_startAudio*(self: tuck_type_PodcastApp): void =
  return

proc tuck_type_PodcastApp_tuck_fn_setMany*(self: var tuck_type_PodcastApp, pairs: seq[tuck_type_Pair]): TuckResult[tuple[]] =
  discard

proc tuck_type_PodcastApp_play*(self: var tuck_type_PodcastApp, episode: tuck_type_Episode): void =
  var tuckChain1 = self
  tuckChain1 = tuck_fn_loadEpisode(tuckChain1, episode)
  tuck_fn_startAudio(tuckChain1)


