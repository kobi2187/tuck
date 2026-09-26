{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import net
import scheduler

proc tuck_fn_done*(): bool
proc tuck_fn_main*(): int

type tuck_type_ResultMsgKind* = enum msgPut
type tuck_type_ResultMsg* = object
  tuckTag*: tuck_type_ResultMsgKind
  c*: int

type tuck_type_Result* = ref object
  code*: int
  ready*: bool
  mailbox*: Mailbox[tuck_type_ResultMsg, 8]

let tuck_type_ResultSingleton* = tuck_type_Result(code: 0, ready: false)

proc handleMsg*(self: tuck_type_Result, msg: tuck_type_ResultMsg) =
  case msg.tuckTag
  of msgPut:
    let c = msg.c
    if true:
      self.code = c
      self.ready = true

proc draintuck_type_Result(): bool {.gcsafe.} =
  {.cast(gcsafe).}:
    result = false
    for m in messages(tuck_type_ResultSingleton.mailbox):
      handleMsg(tuck_type_ResultSingleton, m)
      tuckCheckWaiters()
      result = true

var tuck_type_ResultSlot*: pointer
proc registerActortuck_type_Result*() =
  tuck_type_ResultSlot = tuckStartActor(draintuck_type_Result)

proc tuck_fn_serve*(lfd: int): void =
  var tuck_c = net.accept(lfd)
  if tuck_c.ok:
    if true:
      discard net.recv(tuck_c.value.fd, 256)
      discard net.send(tuck_c.value.fd, "pong")
      net.close(tuck_c.value.fd)
  return

proc tuck_fn_client*(port: int): void =
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
              discard enqueue(tuck_type_ResultSingleton.mailbox, tuck_type_ResultMsg(tuckTag: msgPut, c: 42))
              tuckNotifySend(tuck_type_ResultSlot)
              return
      discard enqueue(tuck_type_ResultSingleton.mailbox, tuck_type_ResultMsg(tuckTag: msgPut, c: 3))
      tuckNotifySend(tuck_type_ResultSlot)
      return
  discard enqueue(tuck_type_ResultSingleton.mailbox, tuck_type_ResultMsg(tuckTag: msgPut, c: 4))
  tuckNotifySend(tuck_type_ResultSlot)
  return

proc tuck_fn_done*(): bool =
  return tuck_type_ResultSingleton.ready

proc tuck_fn_main*(): int =
  var tuck_l = net.listen(34593)
  if tuck_l.ok:
    if true:
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_fn_serve(tuck_l.value.fd)))
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_fn_client(34593)))
      tuckWaitOn(tuck_type_ResultSlot, tuck_fn_done)
      net.close(tuck_l.value.fd)
      scheduler.stop()
      return tuck_type_ResultSingleton.code
  return 1

