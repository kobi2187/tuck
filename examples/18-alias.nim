{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑplayTrack*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: playTrack invoked (not implemented)")

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑexternalTrack = (trackId: 42, title: "Slow Jam", durationMs: 215000)
  var tuckˑvˑplayerInput = (id: tuckˑvˑexternalTrack.trackId, name: tuckˑvˑexternalTrack.title, length: tuckˑvˑexternalTrack.durationMs)
  tuckˑfnˑplayTrack(tuckˑvˑplayerInput)
  return

