{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import http

type tuck_type_Feed* = object
  episodes*: int

proc tuck_fn_parse*[T](payload: T): tuple[feed: tuck_type_Feed] =
  stderr.writeLine("TUCK PENDING: tuck_fn_parse invoked (not implemented)")


proc tuck_fn_fetchFeed*(url: string): TuckResult[tuple[feed: tuck_type_Feed]] =
  var tuck_resp = http.tuck_fn_get(url)
  if tuck_resp.ok:
    if true:
      return tok(tuck_fn_parse(tuck_resp.value.body))
  return terr[tuple[feed: tuck_type_Feed]](uint16(tuck_resp.err))

