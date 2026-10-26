{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import http as tuckˑmodˑhttp

type tuckˑtypeˑFeed* = object
  episodes*: int

proc tuckˑfnˑparse*[T0](p0: T0): tuple[feed: tuckˑtypeˑFeed] =
  stderr.writeLine("TUCK PENDING: parse invoked (not implemented)")


proc tuckˑtaskˑfetchFeed*(url: string): TuckResult[tuple[feed: tuckˑtypeˑFeed]] =
  var tuckˑvˑresp = tuckˑmodˑhttp.tuckˑfnˑget(url)
  defer: tuckDrop(tuckˑvˑresp)
  if tuckˑvˑresp.ok:
    if true:
      return tok(tuckˑfnˑparse(tuckˑvˑresp.value.body))
  return terr[tuple[feed: tuckˑtypeˑFeed]](uint16(tuckˑvˑresp.err))

