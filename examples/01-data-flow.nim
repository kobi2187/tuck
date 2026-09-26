{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import time

proc tuck_fn_main*(): void

proc tuck_fn_fetch*[T](payload: T): tuple[hasNew: bool, episodes: int, metadata: string] =
  stderr.writeLine("TUCK PENDING: tuck_fn_fetch invoked (not implemented)")

proc tuck_fn_parse*[T](payload: T): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: tuck_fn_parse invoked (not implemented)")

proc tuck_fn_selectEpisodes*[T](payload: T): tuple[episodes: int] =
  stderr.writeLine("TUCK PENDING: tuck_fn_selectEpisodes invoked (not implemented)")

proc tuck_fn_process*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_fn_process invoked (not implemented)")

proc tuck_fn_log*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_fn_log invoked (not implemented)")

proc tuck_fn_playTrack*[T](payload: T): void =
  stderr.writeLine("TUCK PENDING: tuck_fn_playTrack invoked (not implemented)")


proc tuck_fn_main*(): void =
  var tuck_request = (url: "example.com", timeout: tuck_fn_ms(5'u32))
  var tuck_response = tuck_fn_selectEpisodes(tuck_fn_parse(tuck_fn_fetch(tuck_request)))
  var tuck_feed = tuck_fn_fetch("https://example.com/feed")
  if tuck_feed.hasNew:
    if true:
      tuck_fn_process(tuck_feed.episodes)
  else:
    if true:
      tuck_fn_log(tuck_feed.metadata)
  var tuck_externalTrack = (trackId: 101, title: "Deep Dive", durationMs: 212000)
  var tuck_normalizedTrack = (id: tuck_externalTrack.trackId, name: tuck_externalTrack.title, length: tuck_externalTrack.durationMs)
  tuck_fn_playTrack(tuck_normalizedTrack)
  return

