{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import http as tuckˑmodˑhttp

type tuckˑtypeˑFeed* = object
  episodes*: int

proc tuckˑfnˑparse*[T0](p0: T0): tuple[feed: tuckˑtypeˑFeed] =
  stderr.writeLine("TUCK PENDING: parse invoked (not implemented)")


type TuckFˑtuckˑtaskˑfetchFeed* = object
    tuckHdr: TuckFrameHdr
    tuckRes: ptr TuckSlot[TuckResult[tuple[feed: tuckˑtypeˑFeed]]]
    tuckDest: ptr TuckResult[tuple[feed: tuckˑtypeˑFeed]]
    url: string
    tuckˑvˑresp: TuckResult[tuple[body: string]]
    tuckDefer0: bool

proc TuckSˑtuckˑtaskˑfetchFeedˑ0(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑfetchFeedˑ1(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑfetchFeedˑ0(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑfetchFeedˑ2(env: pointer): TuckHop {.nimcall.}
proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑfetchFeed)
proc TuckXˑtuckˑtaskˑfetchFeedˑ0(tuckF: ptr TuckFˑtuckˑtaskˑfetchFeed)
proc TuckNewˑtuckˑtaskˑfetchFeed*(tuckAt: ptr TuckFˑtuckˑtaskˑfetchFeed, tuckRes: ptr TuckSlot[TuckResult[tuple[feed: tuckˑtypeˑFeed]]], tuckDest: ptr TuckResult[tuple[feed: tuckˑtypeˑFeed]], url: string): ptr TuckFˑtuckˑtaskˑfetchFeed =
  if tuckAt == nil: result = tuckSlAlloc(TuckFˑtuckˑtaskˑfetchFeed)
  else:
    zeroMem(tuckAt, sizeof(TuckFˑtuckˑtaskˑfetchFeed))
    result = tuckAt
    result.tuckHdr.embedded = true
  result.tuckHdr.stage = TuckSˑtuckˑtaskˑfetchFeedˑ0
  result.tuckRes = tuckRes
  result.tuckDest = tuckDest
  tuckStore(result.url, url)

proc TuckSˑtuckˑtaskˑfetchFeedˑ0(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfetchFeed](env)
  template url: untyped = tuckF.url
  template tuckˑvˑresp: untyped = tuckF.tuckˑvˑresp
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑfetchFeedˑ1)

proc TuckSˑtuckˑtaskˑfetchFeedˑ1(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfetchFeed](env)
  template url: untyped = tuckF.url
  template tuckˑvˑresp: untyped = tuckF.tuckˑvˑresp
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑfetchFeedˑ2, TuckIOˑtuckˑtaskˑfetchFeedˑ0)

proc TuckSˑtuckˑtaskˑfetchFeedˑ2(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfetchFeed](env)
  template url: untyped = tuckF.url
  template tuckˑvˑresp: untyped = tuckF.tuckˑvˑresp
  tuckF.tuckDefer0 = true
  if tuckˑvˑresp.ok:
    if true:
      return tuckSlRet(tuckF, tok(tuckˑfnˑparse(tuckˑvˑresp.value.body)))
  return tuckSlRet(tuckF, terr[tuple[feed: tuckˑtypeˑFeed]](uint16(tuckˑvˑresp.err)))

proc TuckIOˑtuckˑtaskˑfetchFeedˑ0(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfetchFeed](env)
  template url: untyped = tuckF.url
  template tuckˑvˑresp: untyped = tuckF.tuckˑvˑresp
  tuckStore(tuckˑvˑresp, tuckˑmodˑhttp.tuckˑfnˑget(url))
  discard

proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑfetchFeed) =
  template url: untyped = tuckF.url
  template tuckˑvˑresp: untyped = tuckF.tuckˑvˑresp
  if tuckF.tuckDefer0:
    tuckDrop(tuckˑvˑresp)
    tuckF.tuckDefer0 = false
  discard

proc TuckXˑtuckˑtaskˑfetchFeedˑ0(tuckF: ptr TuckFˑtuckˑtaskˑfetchFeed) =
  template url: untyped = tuckF.url
  template tuckˑvˑresp: untyped = tuckF.tuckˑvˑresp
  if tuckF.tuckDefer0:
    tuckDrop(tuckˑvˑresp)
    tuckF.tuckDefer0 = false


