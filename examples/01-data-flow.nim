{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import time

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑfetch*[T](payload: T): tuple[hasNew: bool, episodes: int, metadata: string] =
  stderr.writeLine("TUCK PENDING: fetch invoked (not implemented)")

proc tuckˑfnˑparse*[T](payload: T): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: parse invoked (not implemented)")

proc tuckˑfnˑselectEpisodes*[T](payload: T): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: selectEpisodes invoked (not implemented)")

proc tuckˑfnˑprocess*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: process invoked (not implemented)")

proc tuckˑfnˑlog*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: log invoked (not implemented)")

proc tuckˑfnˑplayTrack*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: playTrack invoked (not implemented)")


proc tuckˑfnˑmain*(): void =
  var tuckˑvˑrequest = (url: tuckCopy("example.com"), timeout: tuckˑfnˑms(5'u32))
  defer: tuckDrop(tuckˑvˑrequest.url)
  var tuckOwnTmp1 = tuckˑfnˑfetch(tuckˑvˑrequest)
  defer: tuckDrop(tuckOwnTmp1.metadata)
  var tuckˑvˑresponse = tuckˑfnˑselectEpisodes(tuckˑfnˑparse(tuckOwnTmp1))
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
  tuckˑfnˑplayTrack(tuckˑvˑnormalizedTrack)
  return

