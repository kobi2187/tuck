{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import net as tuckˑmodˑnet
import scheduler as tuckˑmodˑscheduler

proc tuckˑfnˑdone*(): bool
proc tuckˑfnˑmain*(): int

type tuckˑactorˑResultMsgKind* = enum msgPut
type tuckˑactorˑResultMsg* = object
  tuckTag*: tuckˑactorˑResultMsgKind
  c*: int

type tuckˑactorˑResult* = ref object
  code*: int
  ready*: bool
  mailbox*: Mailbox[tuckˑactorˑResultMsg, 8]

let tuckˑactorˑResultSingleton* = tuckˑactorˑResult(code: 0, ready: false)

proc handleMsg*(self: tuckˑactorˑResult, msg: tuckˑactorˑResultMsg) =
  case msg.tuckTag
  of msgPut:
    let c = msg.c
    if true:
      self.code = c
      self.ready = true

proc draintuckˑactorˑResult(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑResultSingleton.mailbox):
      handleMsg(tuckˑactorˑResultSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑResultSlot*: pointer
proc registerActortuckˑactorˑResult*() =
  tuckˑactorˑResultSlot = tuckStartActorFrame(draintuckˑactorˑResult)

type TuckFˑtuckˑtaskˑserve* = object
    tuckHdr: TuckFrameHdr
    tuckRes: ptr TuckSlot[bool]
    tuckDest: ptr bool
    lfd: int
    tuckˑvˑc: TuckResult[tuple[fd: int]]
    tuckOwnTmp1: TuckResult[tuple[data: string]]
    tuckDefer0: bool

proc TuckSˑtuckˑtaskˑserveˑ0(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ1(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑserveˑ0(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ2(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ3(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ4(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ5(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑserveˑ1(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ6(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ7(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑserveˑ2(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ8(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ9(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑserveˑ3(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ10(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑserveˑ11(env: pointer): TuckHop {.nimcall.}
proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑserve)
proc TuckXˑtuckˑtaskˑserveˑ1(tuckF: ptr TuckFˑtuckˑtaskˑserve)
proc TuckNewˑtuckˑtaskˑserve*(tuckRes: ptr TuckSlot[bool], tuckDest: ptr bool, lfd: int): ptr TuckFˑtuckˑtaskˑserve =
  result = tuckSlAlloc(TuckFˑtuckˑtaskˑserve)
  result.tuckHdr.stage = TuckSˑtuckˑtaskˑserveˑ0
  result.tuckRes = tuckRes
  result.tuckDest = tuckDest
  tuckStore(result.lfd, lfd)

proc TuckSˑtuckˑtaskˑserveˑ0(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ1)

proc TuckSˑtuckˑtaskˑserveˑ1(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ2, TuckIOˑtuckˑtaskˑserveˑ0)

proc TuckSˑtuckˑtaskˑserveˑ2(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  if tuckˑvˑc.ok: return TuckSˑtuckˑtaskˑserveˑ4(env)
  else: return TuckSˑtuckˑtaskˑserveˑ11(env)

proc TuckSˑtuckˑtaskˑserveˑ3(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlRetVoid(tuckF)

proc TuckSˑtuckˑtaskˑserveˑ4(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ5)

proc TuckSˑtuckˑtaskˑserveˑ5(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ6, TuckIOˑtuckˑtaskˑserveˑ1)

proc TuckSˑtuckˑtaskˑserveˑ6(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  tuckF.tuckDefer0 = true
  discard tuckOwnTmp1
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ7)

proc TuckSˑtuckˑtaskˑserveˑ7(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ8, TuckIOˑtuckˑtaskˑserveˑ2)

proc TuckSˑtuckˑtaskˑserveˑ8(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ9)

proc TuckSˑtuckˑtaskˑserveˑ9(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ10, TuckIOˑtuckˑtaskˑserveˑ3)

proc TuckSˑtuckˑtaskˑserveˑ10(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  TuckXˑtuckˑtaskˑserveˑ1(tuckF)
  return TuckSˑtuckˑtaskˑserveˑ3(env)

proc TuckSˑtuckˑtaskˑserveˑ11(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  return TuckSˑtuckˑtaskˑserveˑ3(env)

proc TuckIOˑtuckˑtaskˑserveˑ0(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  tuckˑvˑc = tuckˑmodˑnet.accept(lfd)
  discard

proc TuckIOˑtuckˑtaskˑserveˑ1(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  tuckStore(tuckOwnTmp1, tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256))
  discard

proc TuckIOˑtuckˑtaskˑserveˑ2(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  discard tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "pong")
  discard

proc TuckIOˑtuckˑtaskˑserveˑ3(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑserve](env)
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  tuckˑmodˑnet.close(tuckˑvˑc.value.fd)
  discard

proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑserve) =
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  if tuckF.tuckDefer0:
    tuckDrop(tuckOwnTmp1)
    tuckF.tuckDefer0 = false
  discard

proc TuckXˑtuckˑtaskˑserveˑ1(tuckF: ptr TuckFˑtuckˑtaskˑserve) =
  template lfd: untyped = tuckF.lfd
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckOwnTmp1: untyped = tuckF.tuckOwnTmp1
  if tuckF.tuckDefer0:
    tuckDrop(tuckOwnTmp1)
    tuckF.tuckDefer0 = false


type TuckFˑtuckˑtaskˑclient* = object
    tuckHdr: TuckFrameHdr
    tuckRes: ptr TuckSlot[bool]
    tuckDest: ptr bool
    port: int
    tuckˑvˑc: TuckResult[tuple[fd: int]]
    tuckˑvˑr: TuckResult[tuple[data: string]]
    tuckDefer0: bool

proc TuckSˑtuckˑtaskˑclientˑ0(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ1(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ0(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ2(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ3(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ6(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ4(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ5(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ1(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ6(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ7(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ2(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ8(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ9(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ3(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ10(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ11(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ5(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ12(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ13(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ14(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑclientˑ4(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ15(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ16(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ17(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ18(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ19(env: pointer): TuckHop {.nimcall.}
proc TuckSˑtuckˑtaskˑclientˑ20(env: pointer): TuckHop {.nimcall.}
proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑclient)
proc TuckXˑtuckˑtaskˑclientˑ1(tuckF: ptr TuckFˑtuckˑtaskˑclient)
proc TuckNewˑtuckˑtaskˑclient*(tuckRes: ptr TuckSlot[bool], tuckDest: ptr bool, port: int): ptr TuckFˑtuckˑtaskˑclient =
  result = tuckSlAlloc(TuckFˑtuckˑtaskˑclient)
  result.tuckHdr.stage = TuckSˑtuckˑtaskˑclientˑ0
  result.tuckRes = tuckRes
  result.tuckDest = tuckDest
  tuckStore(result.port, port)

proc TuckSˑtuckˑtaskˑclientˑ0(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ1)

proc TuckSˑtuckˑtaskˑclientˑ1(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ2, TuckIOˑtuckˑtaskˑclientˑ0)

proc TuckSˑtuckˑtaskˑclientˑ2(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  if tuckˑvˑc.ok: return TuckSˑtuckˑtaskˑclientˑ4(env)
  else: return TuckSˑtuckˑtaskˑclientˑ19(env)

proc TuckSˑtuckˑtaskˑclientˑ3(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ20, TuckIOˑtuckˑtaskˑclientˑ6)

proc TuckSˑtuckˑtaskˑclientˑ4(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ5)

proc TuckSˑtuckˑtaskˑclientˑ5(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ6, TuckIOˑtuckˑtaskˑclientˑ1)

proc TuckSˑtuckˑtaskˑclientˑ6(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ7)

proc TuckSˑtuckˑtaskˑclientˑ7(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ8, TuckIOˑtuckˑtaskˑclientˑ2)

proc TuckSˑtuckˑtaskˑclientˑ8(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  tuckF.tuckDefer0 = true
  return tuckSlYield(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ9)

proc TuckSˑtuckˑtaskˑclientˑ9(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ10, TuckIOˑtuckˑtaskˑclientˑ3)

proc TuckSˑtuckˑtaskˑclientˑ10(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  if tuckˑvˑr.ok: return TuckSˑtuckˑtaskˑclientˑ12(env)
  else: return TuckSˑtuckˑtaskˑclientˑ17(env)

proc TuckSˑtuckˑtaskˑclientˑ11(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ18, TuckIOˑtuckˑtaskˑclientˑ5)

proc TuckSˑtuckˑtaskˑclientˑ12(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  if (tuckˑvˑr.value.data == "pong"): return TuckSˑtuckˑtaskˑclientˑ14(env)
  else: return TuckSˑtuckˑtaskˑclientˑ16(env)

proc TuckSˑtuckˑtaskˑclientˑ13(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return TuckSˑtuckˑtaskˑclientˑ11(env)

proc TuckSˑtuckˑtaskˑclientˑ14(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ15, TuckIOˑtuckˑtaskˑclientˑ4)

proc TuckSˑtuckˑtaskˑclientˑ15(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlRetVoid(tuckF)

proc TuckSˑtuckˑtaskˑclientˑ16(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return TuckSˑtuckˑtaskˑclientˑ13(env)

proc TuckSˑtuckˑtaskˑclientˑ17(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return TuckSˑtuckˑtaskˑclientˑ11(env)

proc TuckSˑtuckˑtaskˑclientˑ18(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlRetVoid(tuckF)

proc TuckSˑtuckˑtaskˑclientˑ19(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return TuckSˑtuckˑtaskˑclientˑ3(env)

proc TuckSˑtuckˑtaskˑclientˑ20(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  return tuckSlRetVoid(tuckF)

proc TuckIOˑtuckˑtaskˑclientˑ0(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  tuckˑvˑc = tuckˑmodˑnet.connect("127.0.0.1", port)
  discard

proc TuckIOˑtuckˑtaskˑclientˑ6(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  sendWaiting(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 4), tuckˑactorˑResultSlot, "Result")
  tuckNotifySend(tuckˑactorˑResultSlot)
  discard

proc TuckIOˑtuckˑtaskˑclientˑ1(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  discard tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "ping")
  discard

proc TuckIOˑtuckˑtaskˑclientˑ2(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  tuckStore(tuckˑvˑr, tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256))
  discard

proc TuckIOˑtuckˑtaskˑclientˑ3(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  tuckˑmodˑnet.close(tuckˑvˑc.value.fd)
  discard

proc TuckIOˑtuckˑtaskˑclientˑ5(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  sendWaiting(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 3), tuckˑactorˑResultSlot, "Result")
  tuckNotifySend(tuckˑactorˑResultSlot)
  discard

proc TuckIOˑtuckˑtaskˑclientˑ4(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑclient](env)
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  sendWaiting(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 42), tuckˑactorˑResultSlot, "Result")
  tuckNotifySend(tuckˑactorˑResultSlot)
  discard

proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑclient) =
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  if tuckF.tuckDefer0:
    tuckDrop(tuckˑvˑr)
    tuckF.tuckDefer0 = false
  discard

proc TuckXˑtuckˑtaskˑclientˑ1(tuckF: ptr TuckFˑtuckˑtaskˑclient) =
  template port: untyped = tuckF.port
  template tuckˑvˑc: untyped = tuckF.tuckˑvˑc
  template tuckˑvˑr: untyped = tuckF.tuckˑvˑr
  if tuckF.tuckDefer0:
    tuckDrop(tuckˑvˑr)
    tuckF.tuckDefer0 = false


proc tuckˑfnˑdone*(): bool =
  return tuckˑactorˑResultSingleton.ready

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑl = tuckˑmodˑnet.listen(34593)
  if tuckˑvˑl.ok:
    if true:
      tuckSlReady(addr TuckNewˑtuckˑtaskˑserve(nil, nil, tuckˑvˑl.value.fd).tuckHdr)
      tuckSlReady(addr TuckNewˑtuckˑtaskˑclient(nil, nil, 34593).tuckHdr)
      tuckWaitOn(tuckˑactorˑResultSlot, tuckˑfnˑdone)
      tuckˑmodˑnet.close(tuckˑvˑl.value.fd)
      tuckˑmodˑscheduler.stop()
      return tuckˑactorˑResultSingleton.code
  return 1

