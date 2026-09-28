{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import net
import scheduler

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
  var tuckˑvˑc = net.accept(lfd)
  if tuckˑvˑc.ok:
    if true:
      discard net.recv(tuckˑvˑc.value.fd, 256)
      discard net.send(tuckˑvˑc.value.fd, "pong")
      net.close(tuckˑvˑc.value.fd)
  return

proc tuckˑtaskˑclient*(port: int): void =
  var tuckˑvˑc = net.connect("127.0.0.1", port)
  if tuckˑvˑc.ok:
    if true:
      discard net.send(tuckˑvˑc.value.fd, "ping")
      var tuckˑvˑr = net.recv(tuckˑvˑc.value.fd, 256)
      net.close(tuckˑvˑc.value.fd)
      if tuckˑvˑr.ok:
        if true:
          if (tuckˑvˑr.value.data == "pong"):
            if true:
              discard enqueue(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 42))
              tuckNotifySend(tuckˑactorˑResultSlot)
              return
      discard enqueue(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 3))
      tuckNotifySend(tuckˑactorˑResultSlot)
      return
  discard enqueue(tuckˑactorˑResultSingleton.mailbox, tuckˑactorˑResultMsg(tuckTag: msgPut, c: 4))
  tuckNotifySend(tuckˑactorˑResultSlot)
  return

proc tuckˑfnˑdone*(): bool =
  return tuckˑactorˑResultSingleton.ready

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑl = net.listen(34593)
  if tuckˑvˑl.ok:
    if true:
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuckˑtaskˑserve(tuckˑvˑl.value.fd)))
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuckˑtaskˑclient(34593)))
      tuckWaitOn(tuckˑactorˑResultSlot, tuckˑfnˑdone)
      net.close(tuckˑvˑl.value.fd)
      scheduler.stop()
      return tuckˑactorˑResultSingleton.code
  return 1

