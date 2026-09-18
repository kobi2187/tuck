{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import net
import scheduler

proc tuck_done*(): bool
proc tuck_main*(): int

type tuck_ResultMsgKind* = enum msgPut
type tuck_ResultMsg* = object
  tuckTag*: tuck_ResultMsgKind
  c*: int

type tuck_Result* = ref object
  code*: int
  ready*: bool
  mailbox*: Mailbox[tuck_ResultMsg, 8]

let tuck_ResultSingleton* = tuck_Result()

proc handleMsg*(self: tuck_Result, msg: tuck_ResultMsg) =
  case msg.tuckTag
  of msgPut:
    let c = msg.c
    if true:
      self.code = c
      self.ready = true

proc draintuck_Result(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    var m: tuck_ResultMsg
    while dequeue(tuck_ResultSingleton.mailbox, m):
      handleMsg(tuck_ResultSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_ResultSlot*: pointer
proc registerActortuck_Result*() =
  tuck_ResultSlot = tuckStartActor(draintuck_Result)

proc tuck_serve*(lfd: int): void =
  var tuck_c = net.accept(lfd)
  if tuck_c.ok:
    if true:
      discard net.recv(tuck_c.value.fd, 256)
      discard net.send(tuck_c.value.fd, "pong")
      net.close(tuck_c.value.fd)
  return

proc tuck_client*(port: int): void =
  var tuck_c = net.connect("127.0.0.1", port)
  if tuck_c.ok:
    if true:
      discard net.send(tuck_c.value.fd, "ping")
      var tuck_r = net.recv(tuck_c.value.fd, 256)
      net.close(tuck_c.value.fd)
      if tuck_r.ok:
        if true:
          if (tuck_r.value.data == "pong"):
            if true:
              discard enqueue(tuck_ResultSingleton.mailbox, tuck_ResultMsg(tuckTag: msgPut, c: 42))
              tuckNotifySend()
              return
      discard enqueue(tuck_ResultSingleton.mailbox, tuck_ResultMsg(tuckTag: msgPut, c: 3))
      tuckNotifySend()
      return
  discard enqueue(tuck_ResultSingleton.mailbox, tuck_ResultMsg(tuckTag: msgPut, c: 4))
  tuckNotifySend()
  return

proc tuck_done*(): bool =
  return tuck_ResultSingleton.ready

proc tuck_main*(): int =
  var tuck_l = net.listen(34593)
  if tuck_l.ok:
    if true:
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_serve(tuck_l.value.fd)))
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_client(34593)))
      tuckWaitOn(tuck_ResultSlot, tuck_done)
      net.close(tuck_l.value.fd)
      scheduler.stop()
      return tuck_ResultSingleton.code
  return 1

