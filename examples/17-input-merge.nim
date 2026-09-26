{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑdescribe*(title: sink string, volume: int): string
proc tuckˑfnˑheader*(episode: tuckˑtypeˑEpisode, n: int): string
proc tuckˑfnˑplay*(episode: sink tuckˑtypeˑEpisode, prefs: tuckˑtypeˑPlayerPrefs): string

type tuckˑtypeˑEpisode* = object
  title*: string
  duration*: uint32
  playSpeed*: float

type tuckˑtypeˑPlayerPrefs* = object
  volume*: int
  speed*: float

proc tuckˑfnˑdescribe*(title: sink string, volume: int): string =
  return title

proc tuckˑfnˑheader*(episode: tuckˑtypeˑEpisode, n: int): string =
  return episode.title

proc tuckˑfnˑplay*(episode: sink tuckˑtypeˑEpisode, prefs: tuckˑtypeˑPlayerPrefs): string =
  var tuckˑvˑctx = (title: episode.title, duration: episode.duration, playSpeed: episode.playSpeed, volume: prefs.volume, speed: prefs.speed)
  return tuckˑfnˑdescribe(tuckˑvˑctx.title, tuckˑvˑctx.volume)

