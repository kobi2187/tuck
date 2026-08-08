import ../compiler/tuck_rt

type tuck_Episode* = object
    title*: string
    duration*: uint32
    playSpeed*: float

type tuck_PlayerPrefs* = object
    volume*: int
    speed*: float

proc tuck_describe*(title: string, volume: int): string =
  return title

proc tuck_header*(episode: var tuck_Episode, n: int): string =
  return episode.title

proc tuck_play*(episode: var tuck_Episode, prefs: var tuck_PlayerPrefs): string =
  var ctx = (title: episode.title, duration: episode.duration, playSpeed: episode.playSpeed, volume: prefs.volume, speed: prefs.speed)
  return tuck_describe(ctx.title, ctx.volume)

