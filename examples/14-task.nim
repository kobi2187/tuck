{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import http

type tuckˑtypeˑFeed* = object
  episodes*: int

proc tuckˑfnˑparse*[T](payload: T): tuple[feed: tuckˑtypeˑFeed] =
  stderr.writeLine("TUCK PENDING: parse invoked (not implemented)")


proc tuckˑtaskˑfetchFeed*(url: string): TuckResult[tuple[feed: tuckˑtypeˑFeed]] =
  var tuckˑvˑresp = http.tuckˑfnˑget(url)
  if tuckˑvˑresp.ok:
    if true:
      return tok(tuckˑfnˑparse(tuckˑvˑresp.value.body))
  return terr[tuple[feed: tuckˑtypeˑFeed]](uint16(tuckˑvˑresp.err))

