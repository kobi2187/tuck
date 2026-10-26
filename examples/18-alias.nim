{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑplayTrack*[T0, T1, T2](p0: T0, p1: T1, p2: T2): void =
  stderr.writeLine("TUCK PENDING: playTrack invoked (not implemented)")

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑexternalTrack = (trackId: 42, title: tuckCopy("Slow Jam"), durationMs: 215000)
  var tuckˑvˑplayerInput = (id: tuckˑvˑexternalTrack.trackId, name: tuckMove(tuckˑvˑexternalTrack.title), length: tuckˑvˑexternalTrack.durationMs)
  defer: tuckDrop(tuckˑvˑplayerInput.name)
  tuckˑfnˑplayTrack(tuckˑvˑplayerInput.id, tuckˑvˑplayerInput.name, tuckˑvˑplayerInput.length)
  return

