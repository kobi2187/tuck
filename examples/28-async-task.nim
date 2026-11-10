{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc tuckˑfnˑstepIo*(n: int): tuple[v: int]
proc tuckˑfnˑmain*(): int

proc tuckˑfnˑstepIo*(n: int): tuple[v: int] =
  return (v: n)

type TuckFˑtuckˑtaskˑcompute* = object
    tuckHdr*: TuckFrameHdr
    tuckRes*: ptr TuckSlot[tuple[r: int]]
    tuckDest*: ptr tuple[r: int]
    base: int
    tuckˑvˑa: tuple[v: int]
    tuckˑvˑb: tuple[v: int]

proc TuckSˑtuckˑtaskˑcomputeˑ0*(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑcomputeˑ1*(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑcomputeˑ2*(env: pointer): TuckHop {.nimcall.}
proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑcompute)
proc TuckNewˑtuckˑtaskˑcompute*(tuckAt: ptr TuckFˑtuckˑtaskˑcompute, tuckRes: ptr TuckSlot[tuple[r: int]], tuckDest: ptr tuple[r: int], base: int): ptr TuckFˑtuckˑtaskˑcompute =
  if tuckAt == nil: result = tuckSlAlloc(TuckFˑtuckˑtaskˑcompute)
  else:
    zeroMem(tuckAt, sizeof(TuckFˑtuckˑtaskˑcompute))
    result = tuckAt
    result.tuckHdr.embedded = true
  result.tuckHdr.stage = TuckSˑtuckˑtaskˑcomputeˑ0
  result.tuckRes = tuckRes
  result.tuckDest = tuckDest
  tuckStore(result.base, base)

proc TuckSˑtuckˑtaskˑcomputeˑ0*(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑcompute](env)
  template base: untyped = tuckF.base
  template tuckˑvˑa: untyped = tuckF.tuckˑvˑa
  template tuckˑvˑb: untyped = tuckF.tuckˑvˑb
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑcomputeˑ1)

proc TuckSˑtuckˑtaskˑcomputeˑ1*(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑcompute](env)
  template base: untyped = tuckF.base
  template tuckˑvˑa: untyped = tuckF.tuckˑvˑa
  template tuckˑvˑb: untyped = tuckF.tuckˑvˑb
  tuckˑvˑa = tuckˑfnˑstepIo(base)
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑcomputeˑ2)

proc TuckSˑtuckˑtaskˑcomputeˑ2*(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑcompute](env)
  template base: untyped = tuckF.base
  template tuckˑvˑa: untyped = tuckF.tuckˑvˑa
  template tuckˑvˑb: untyped = tuckF.tuckˑvˑb
  tuckˑvˑb = tuckˑfnˑstepIo(base)
  return tuckSlRet(tuckF, (r: (tuckˑvˑa.v + tuckˑvˑb.v)))

proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑcompute) =
  template base: untyped = tuckF.base
  template tuckˑvˑa: untyped = tuckF.tuckˑvˑa
  template tuckˑvˑb: untyped = tuckF.tuckˑvˑb
  discard


proc tuckˑfnˑmain*(): int =
  var tuckˑvˑres = (var tuckSlot0: TuckSlot[tuple[r: int]]; var tuckSlot0F: TuckFˑtuckˑtaskˑcompute; tuckSlReady(addr TuckNewˑtuckˑtaskˑcompute(addr tuckSlot0F, addr tuckSlot0, nil, 21).tuckHdr); tuckSlAwaitMain(addr tuckSlot0))
  return tuckˑvˑres.r

