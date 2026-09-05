{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import http

type tuck_Feed* = object
  episodes*: int

proc tuck_parse*[T](payload: T): tuple[feed: tuck_Feed] =
  stderr.writeLine("TUCK PENDING: tuck_parse invoked (not implemented)")


proc tuck_fetchFeed*(url: string): TuckResult[tuple[feed: tuck_Feed]] =
  var tuck_resp = http.tuck_get(url)
  if tuck_resp.ok:
    if true:
      return tok(tuck_parse(tuck_resp.value.body))
  return terr[tuple[feed: tuck_Feed]](uint16(tuck_resp.err))

