{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_main*(): void

proc tuck_fn_playTrack*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_fn_playTrack invoked (not implemented)")

proc tuck_fn_main*(): void =
  var tuck_externalTrack = (trackId: 42, title: "Slow Jam", durationMs: 215000)
  var tuck_playerInput = (id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs)
  tuck_fn_playTrack(tuck_playerInput)
  return

