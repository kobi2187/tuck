{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_playTrack*(id: int, name: string, length: int): void =
  discard

proc tuck_main*(): void =
  var externalTrack = (trackId: 42, title: "Slow Jam", durationMs: 215000)
  var playerInput = (id: externalTrack.trackId, name: externalTrack.title, length: externalTrack.durationMs)
  tuck_playTrack(playerInput.id, playerInput.name, playerInput.length)
  return

