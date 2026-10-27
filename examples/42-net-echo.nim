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
  tuckˑactorˑResultSlot = tuckStartActor(draintuckˑactorˑResult)

proc tuckˑtaskˑserve*(lfd: int): void =
  var tuckˑvˑc = (tuckYield(); tuckˑmodˑnet.accept(lfd))
  if tuckˑvˑc.ok:
    if true:
      var tuckOwnTmp1 = (tuckYield(); tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256))
      defer: tuckDrop(tuckOwnTmp1)
      discard tuckOwnTmp1
      discard (tuckYield(); tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "pong"))
      (tuckYield(); tuckˑmodˑnet.close(tuckˑvˑc.value.fd))
  return

proc tuckˑtaskˑclient*(port: int): void =
  var tuckˑvˑc = (tuckYield(); tuckˑmodˑnet.connect("127.0.0.1", port))
  if tuckˑvˑc.ok:
    if true:
      discard (tuckYield(); tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "ping"))
      var tuckˑvˑr = (tuckYield(); tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256))
      defer: tuckDrop(tuckˑvˑr)
      (tuckYield(); tuckˑmodˑnet.close(tuckˑvˑc.value.fd))
      if tuckˑvˑr.ok:
        if true:
          if (tuckˑvˑr.value.data == "pong"):
            if true:
              sendWaiting(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 42), tuckˑactorˑResultSlot, "Result")
              tuckNotifySend(tuckˑactorˑResultSlot)
              return
      sendWaiting(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 3), tuckˑactorˑResultSlot, "Result")
      tuckNotifySend(tuckˑactorˑResultSlot)
      return
  sendWaiting(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 4), tuckˑactorˑResultSlot, "Result")
  tuckNotifySend(tuckˑactorˑResultSlot)
  return

proc tuckˑfnˑdone*(): bool =
  return tuckˑactorˑResultSingleton.ready

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑl = tuckˑmodˑnet.listen(34593)
  if tuckˑvˑl.ok:
    if true:
      tuckSpawnJob(tuckˑtaskˑserve, tuckˑvˑl.value.fd)
      tuckSpawnJob(tuckˑtaskˑclient, 34593)
      tuckWaitOn(tuckˑactorˑResultSlot, tuckˑfnˑdone)
      tuckˑmodˑnet.close(tuckˑvˑl.value.fd)
      tuckˑmodˑscheduler.stop()
      return tuckˑactorˑResultSingleton.code
  return 1

