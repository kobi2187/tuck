{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc tuckˑfnˑdescribe*(title: string, volume: int): string
proc tuckˑfnˑheader*(episode: tuckˑtypeˑEpisode, n: int): string
proc tuckˑfnˑplay*(episode: tuckˑtypeˑEpisode, prefs: tuckˑtypeˑPlayerPrefs): string

type tuckˑtypeˑEpisode* = object
  title*: string
  duration*: uint32
  playSpeed*: float

type tuckˑtypeˑPlayerPrefs* = object
  volume*: int
  speed*: float

proc tuckˑfnˑdescribe*(title: string, volume: int): string =
  var title = tuckBits(title)
  return tuckMove(title)

proc tuckˑfnˑheader*(episode: tuckˑtypeˑEpisode, n: int): string =
  return tuckMove(episode.title)

proc tuckˑfnˑplay*(episode: tuckˑtypeˑEpisode, prefs: tuckˑtypeˑPlayerPrefs): string =
  var episode = tuckBits(episode)
  var tuckˑvˑctx = (title: tuckMove(episode).title, duration: tuckMove(episode).duration, playSpeed: tuckMove(episode).playSpeed, volume: prefs.volume, speed: prefs.speed)
  return tuckˑfnˑdescribe(tuckMove(tuckˑvˑctx).title, tuckMove(tuckˑvˑctx).volume)

