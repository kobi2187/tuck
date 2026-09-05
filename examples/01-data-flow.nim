{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import time

proc tuck_fetch*[T](payload: T): tuple[hasNew: bool, episodes: int, metadata: string] =
  stderr.writeLine("TUCK PENDING: tuck_fetch invoked (not implemented)")

proc tuck_parse*[T](payload: T): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: tuck_parse invoked (not implemented)")

proc tuck_selectEpisodes*[T](payload: T): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: tuck_selectEpisodes invoked (not implemented)")

proc tuck_process*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_process invoked (not implemented)")

proc tuck_log*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_log invoked (not implemented)")

proc tuck_playTrack*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_playTrack invoked (not implemented)")


proc tuck_main*(): void =
  var tuck_request = (url: "example.com", timeout: tuck_ms(5))
  var tuck_response = tuck_selectEpisodes(tuck_parse(tuck_fetch(tuck_request)))
  var tuck_feed = tuck_fetch("https://example.com/feed")
  if tuck_feed.hasNew:
    if true:
      tuck_process(tuck_feed.episodes)
  else:
    if true:
      tuck_log(tuck_feed.metadata)
  var tuck_externalTrack = (trackId: 101, title: "Deep Dive", durationMs: 212000)
  var tuck_normalizedTrack = (id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs)
  tuck_playTrack(tuck_normalizedTrack)
  return

