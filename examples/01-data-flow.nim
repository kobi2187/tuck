{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import time as tuckˑmodˑtime

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑfetch*[T0](p0: T0): tuple[hasNew: bool, episodes: int, metadata: string] =
  stderr.writeLine("TUCK PENDING: fetch invoked (not implemented)")

proc tuckˑfnˑparse*[T0, T1, T2](p0: T0, p1: T1, p2: T2): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: parse invoked (not implemented)")

proc tuckˑfnˑselectEpisodes*[T0](p0: T0): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: selectEpisodes invoked (not implemented)")

proc tuckˑfnˑprocess*[T0](p0: T0): void =
  stderr.writeLine("TUCK PENDING: process invoked (not implemented)")

proc tuckˑfnˑlog*[T0](p0: T0): void =
  stderr.writeLine("TUCK PENDING: log invoked (not implemented)")

proc tuckˑfnˑplayTrack*[T0, T1, T2](p0: T0, p1: T1, p2: T2): void =
  stderr.writeLine("TUCK PENDING: playTrack invoked (not implemented)")


proc tuckˑfnˑmain*(): void =
  var tuckˑvˑrequest = (url: tuckCopy("example.com"), timeout: tuckˑfnˑms(5'u32))
  defer: tuckDrop(tuckˑvˑrequest.url)
  var tuckOwnTmp1 = tuckˑfnˑfetch(tuckˑvˑrequest.url)
  defer: tuckDrop(tuckOwnTmp1.metadata)
  var tuckˑvˑresponse = tuckˑfnˑselectEpisodes(tuckˑfnˑparse(tuckOwnTmp1.hasNew, tuckOwnTmp1.episodes, tuckOwnTmp1.metadata))
  var tuckˑvˑfeed = tuckˑfnˑfetch("https://example.com/feed")
  defer: tuckDrop(tuckˑvˑfeed.metadata)
  if tuckˑvˑfeed.hasNew:
    if true:
      tuckˑfnˑprocess(tuckˑvˑfeed.episodes)
  else:
    if true:
      tuckˑfnˑlog(tuckˑvˑfeed.metadata)
  var tuckˑvˑexternalTrack = (trackId: 101, title: tuckCopy("Deep Dive"), durationMs: 212000)
  var tuckˑvˑnormalizedTrack = (id: tuckˑvˑexternalTrack.trackId, name: tuckMove(tuckˑvˑexternalTrack.title), length: tuckˑvˑexternalTrack.durationMs)
  defer: tuckDrop(tuckˑvˑnormalizedTrack.name)
  tuckˑfnˑplayTrack(tuckˑvˑnormalizedTrack.id, tuckˑvˑnormalizedTrack.name, tuckˑvˑnormalizedTrack.length)
  return

