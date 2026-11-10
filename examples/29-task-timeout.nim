{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
export tuck_rt
import time as tuckˑmodˑtime

proc tuckˑfnˑmain*(): int

type TuckFˑtuckˑtaskˑreadOrGiveUp* = object
    tuckHdr: TuckFrameHdr
    tuckRes: ptr TuckSlot[tuple[code: int]]
    tuckDest: ptr tuple[code: int]
    fd: int
    tuckˑvˑcode: int

proc TuckSˑtuckˑtaskˑreadOrGiveUpˑ0(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑreadOrGiveUpˑ1(env: pointer): TuckHop {.nimcall.}
proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑreadOrGiveUp)
proc TuckNewˑtuckˑtaskˑreadOrGiveUp*(tuckAt: ptr TuckFˑtuckˑtaskˑreadOrGiveUp, tuckRes: ptr TuckSlot[tuple[code: int]], tuckDest: ptr tuple[code: int], fd: int): ptr TuckFˑtuckˑtaskˑreadOrGiveUp =
  if tuckAt == nil: result = tuckSlAlloc(TuckFˑtuckˑtaskˑreadOrGiveUp)
  else:
    zeroMem(tuckAt, sizeof(TuckFˑtuckˑtaskˑreadOrGiveUp))
    result = tuckAt
    result.tuckHdr.embedded = true
  result.tuckHdr.stage = TuckSˑtuckˑtaskˑreadOrGiveUpˑ0
  result.tuckRes = tuckRes
  result.tuckDest = tuckDest
  tuckStore(result.fd, fd)

proc TuckSˑtuckˑtaskˑreadOrGiveUpˑ0(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑreadOrGiveUp](env)
  template fd: untyped = tuckF.fd
  template tuckˑvˑcode: untyped = tuckF.tuckˑvˑcode
  tuckˑvˑcode = 0
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑreadOrGiveUpˑ1, TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0)

proc TuckSˑtuckˑtaskˑreadOrGiveUpˑ1(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑreadOrGiveUp](env)
  template fd: untyped = tuckF.fd
  template tuckˑvˑcode: untyped = tuckF.tuckˑvˑcode
  return tuckSlRet(tuckF, (code: tuckˑvˑcode))

proc TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑreadOrGiveUp](env)
  template fd: untyped = tuckF.fd
  template tuckˑvˑcode: untyped = tuckF.tuckˑvˑcode
  if tuckAwaitReadOrTimeout(fd, int(tuckˑfnˑms(30'u32))):
    tuckˑvˑcode = 1
  else:
    tuckˑvˑcode = 2
  discard

proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑreadOrGiveUp) =
  template fd: untyped = tuckF.fd
  template tuckˑvˑcode: untyped = tuckF.tuckˑvˑcode
  discard


proc tuckˑfnˑmain*(): int =
  var tuckˑvˑsrc = openSource(500)
  var tuckˑvˑr = (var tuckSlot0: TuckSlot[tuple[code: int]]; var tuckSlot0F: TuckFˑtuckˑtaskˑreadOrGiveUp; tuckSlReady(addr TuckNewˑtuckˑtaskˑreadOrGiveUp(addr tuckSlot0F, addr tuckSlot0, nil, tuckˑvˑsrc.fd).tuckHdr); tuckSlAwaitMain(addr tuckSlot0))
  return tuckˑvˑr.code

