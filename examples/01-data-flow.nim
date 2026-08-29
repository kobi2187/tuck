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
  var request = (url: "example.com", timeout: tuck_ms(5))
  var response = tuck_selectEpisodes(tuck_parse(tuck_fetch(request)))
  var feed = tuck_fetch("https://example.com/feed")
  if feed.hasNew:
    if true:
      tuck_process(feed.episodes)
  else:
    if true:
      tuck_log(feed.metadata)
  var externalTrack = (trackId: 101, title: "Deep Dive", durationMs: 212000)
  var normalizedTrack = (id: externalTrack.trackId, name: externalTrack.title, length: externalTrack.durationMs)
  tuck_playTrack(normalizedTrack)
  return

