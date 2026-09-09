{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_playTrack*(id: int, name: string, length: int): void
proc tuck_main*(): void

proc tuck_playTrack*(id: int, name: string, length: int): void =
  discard

proc tuck_main*(): void =
  var tuck_externalTrack = (trackId: 42, title: "Slow Jam", durationMs: 215000)
  var tuck_playerInput = (id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs)
  tuck_playTrack(tuck_playerInput.id, tuck_playerInput.name, tuck_playerInput.length)
  return

