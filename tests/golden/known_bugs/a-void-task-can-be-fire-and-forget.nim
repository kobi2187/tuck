{.experimental: "codeReordering".}
import scheduler as tuckˑmodˑscheduler

proc tuckˑfnˑdone*(): bool
proc tuckˑfnˑmain*(): int

type tuckˑactorˑSinkMsgKind* = enum msgPing
type tuckˑactorˑSinkMsg* = object
  tuckTag*: tuckˑactorˑSinkMsgKind
  n*: int

type tuckˑactorˑSink* = ref object
  hits*: int
  mailbox*: Mailbox[tuckˑactorˑSinkMsg, 8]

let tuckˑactorˑSinkSingleton* = tuckˑactorˑSink(hits: 0)

proc handleMsg*(self: tuckˑactorˑSink, msg: tuckˑactorˑSinkMsg) =
  case msg.tuckTag
  of msgPing:
    let n = msg.n
    if true:
      self.hits = (self.hits + n)

proc draintuckˑactorˑSink(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuckˑactorˑSinkSingleton.mailbox):
      handleMsg(tuckˑactorˑSinkSingleton, m)
      tuckCheckWaiters()
      result = true

var tuckˑactorˑSinkSlot*: pointer
proc registerActortuckˑactorˑSink*() =
  tuckˑactorˑSinkSlot = tuckStartActorFrame(draintuckˑactorˑSink)

type TuckFˑtuckˑtaskˑfire* = object
    tuckHdr*: TuckFrameHdr
    tuckRes*: ptr TuckSlot[bool]
    tuckDest*: ptr bool

proc TuckSˑtuckˑtaskˑfireˑ0*(env: pointer): TuckHop {.nimcall.}
proc TuckIOˑtuckˑtaskˑfireˑ0*(env: pointer) {.nimcall.}
proc TuckSˑtuckˑtaskˑfireˑ1*(env: pointer): TuckHop {.nimcall.}
proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑfire)
proc TuckNewˑtuckˑtaskˑfire*(tuckAt: ptr TuckFˑtuckˑtaskˑfire, tuckRes: ptr TuckSlot[bool], tuckDest: ptr bool): ptr TuckFˑtuckˑtaskˑfire =
  if tuckAt == nil: result = tuckSlAlloc(TuckFˑtuckˑtaskˑfire)
  else:
    zeroMem(tuckAt, sizeof(TuckFˑtuckˑtaskˑfire))
    result = tuckAt
    result.tuckHdr.embedded = true
  result.tuckHdr.stage = TuckSˑtuckˑtaskˑfireˑ0
  result.tuckRes = tuckRes
  result.tuckDest = tuckDest

proc TuckSˑtuckˑtaskˑfireˑ0*(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfire](env)
  return tuckSlOnStack(addr tuckF.tuckHdr, TuckSˑtuckˑtaskˑfireˑ1, TuckIOˑtuckˑtaskˑfireˑ0)

proc TuckSˑtuckˑtaskˑfireˑ1*(env: pointer): TuckHop {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfire](env)
  return tuckSlRetVoid(tuckF)

proc TuckIOˑtuckˑtaskˑfireˑ0*(env: pointer) {.nimcall.} =
  let tuckF = cast[ptr TuckFˑtuckˑtaskˑfire](env)
  sendWaiting(tuckˑactorˑSinkSingleton.mailbox, tuckˑactorˑSinkMsg(tuckTag: msgPing, n: 5), tuckˑactorˑSinkSlot, "Sink")
  tuckNotifySend(tuckˑactorˑSinkSlot)
  discard

proc tuckSlExit(tuckF: ptr TuckFˑtuckˑtaskˑfire) =
  discard


proc tuckˑfnˑdone*(): bool =
  return (tuckˑactorˑSinkSingleton.hits == 5)

proc tuckˑfnˑmain*(): int =
  tuckSlReady(addr TuckNewˑtuckˑtaskˑfire(nil, nil, nil).tuckHdr)
  tuckWaitOn(tuckˑactorˑSinkSlot, tuckˑfnˑdone)
  tuckˑmodˑscheduler.stop()
  return tuckˑactorˑSinkSingleton.hits

