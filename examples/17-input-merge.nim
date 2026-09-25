{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_describe*(title: sink string, volume: int): string
proc tuck_fn_header*(episode: tuck_type_Episode, n: int): string
proc tuck_fn_play*(episode: sink tuck_type_Episode, prefs: tuck_type_PlayerPrefs): string

type tuck_type_Episode* = object
  title*: string
  duration*: uint32
  playSpeed*: float

type tuck_type_PlayerPrefs* = object
  volume*: int
  speed*: float

proc tuck_fn_describe*(title: sink string, volume: int): string =
  return title

proc tuck_fn_header*(episode: tuck_type_Episode, n: int): string =
  return episode.title

proc tuck_fn_play*(episode: sink tuck_type_Episode, prefs: tuck_type_PlayerPrefs): string =
  var tuck_ctx = (title: episode.title, duration: episode.duration, playSpeed: episode.playSpeed, volume: prefs.volume, speed: prefs.speed)
  return tuck_fn_describe(tuck_ctx.title, tuck_ctx.volume)

