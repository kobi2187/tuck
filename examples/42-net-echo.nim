import ../compiler/tuck_rt
import net
import scheduler

type tuck_ResultMsgKind* = enum msgPut
type tuck_ResultMsg* = object
  kind*: tuck_ResultMsgKind
  c*: int

type tuck_Result* = ref object
    code*: int
    ready*: bool
    mailbox*: Mailbox[tuck_ResultMsg, 8]

let tuck_ResultSingleton* = tuck_Result()

proc handleMsg*(self: tuck_Result, msg: tuck_ResultMsg) =
  case msg.kind
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
      result = true

proc registerActortuck_Result*() =
  tuckStartActor(draintuck_Result)

proc tuck_serve*(lfd: int): void =
  var c = net.accept(lfd)
  if c.ok:
    if true:
      var req = net.recv(c.value.fd, 256)
      var s = net.send(c.value.fd, "pong")
      net.close(c.value.fd)
  return

proc tuck_client*(port: int): void =
  var c = net.connect("127.0.0.1", port)
  if c.ok:
    if true:
      var s = net.send(c.value.fd, "ping")
      var r = net.recv(c.value.fd, 256)
      net.close(c.value.fd)
      if r.ok:
        if true:
          if (r.value.data == "pong"):
            if true:
              discard enqueue(tuck_ResultSingleton.mailbox, tuck_ResultMsg(kind: msgPut, c: 42))
              tuckNotifySend()
              return
      discard enqueue(tuck_ResultSingleton.mailbox, tuck_ResultMsg(kind: msgPut, c: 3))
      tuckNotifySend()
      return
  discard enqueue(tuck_ResultSingleton.mailbox, tuck_ResultMsg(kind: msgPut, c: 4))
  tuckNotifySend()
  return

proc tuck_done*(): bool =
  return tuck_ResultSingleton.ready

proc tuck_main*(): int =
  var l = net.listen(34593)
  if l.ok:
    if true:
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_serve(l.value.fd)))
      tuckSpawn(proc() {.closure, gcsafe.} = ({.cast(gcsafe).}: tuck_client(34593)))
      scheduler.waitUntil(tuck_done)
      net.close(l.value.fd)
      scheduler.stop()
      return tuck_ResultSingleton.code
  return 1

