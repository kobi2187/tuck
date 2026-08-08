package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"
import net "./mod_net"

tuck_ResultMsgKind :: enum { msgPut }
tuck_ResultMsg :: struct {
	kind: tuck_ResultMsgKind,
	c: int,
}
tuck_Result :: struct {
	code: int,
	ready: bool,
	mailbox: rt.Mailbox(tuck_ResultMsg, 8),
}

tuck_ResultSingleton: tuck_Result

handleMsg_tuck_Result :: proc(self: ^tuck_Result, msg: tuck_ResultMsg) {
	switch msg.kind {
	case .msgPut:
		c := msg.c
    self.code = c
    self.ready = true
	}
}

drain_tuck_Result :: proc() {
	for {
		msg: tuck_ResultMsg
		for rt.dequeue(&tuck_ResultSingleton.mailbox, &msg) {
			handleMsg_tuck_Result(&tuck_ResultSingleton, msg)
		}
		rt.coroYield()
	}
}

sendPut_tuck_Result :: proc(self: ^tuck_Result, c: int) {
	_ = rt.enqueue(&self.mailbox, tuck_ResultMsg{kind = .msgPut, c = c})
}

tuck_serve :: proc(lfd: int) {
  c := net.accept(lfd)
  if (c.status == .Ok) {
      req := net.recv(c.value.fd, 256)
      s := net.send(c.value.fd, "pong")
      net.close(c.value.fd)
  }
  return
}

tuck_client :: proc(port: int) {
  c := net.connect("127.0.0.1", port)
  if (c.status == .Ok) {
      s := net.send(c.value.fd, "ping")
      r := net.recv(c.value.fd, 256)
      net.close(c.value.fd)
      if (r.status == .Ok) {
          if (r.value.data == "pong") {
              sendPut_tuck_Result(&tuck_ResultSingleton, 42)
              return
          }
      }
      sendPut_tuck_Result(&tuck_ResultSingleton, 3)
      return
  }
  sendPut_tuck_Result(&tuck_ResultSingleton, 4)
  return
}

tuck_done :: proc () -> bool {
  return tuck_ResultSingleton.ready
}

tuck_main :: proc () -> int {
  l := net.listen(34593)
  if (l.status == .Ok) {
      tuck_serve(l.value.fd)
      tuck_client(34593)
      scheduler.waitUntil(tuck_done)
      net.close(l.value.fd)
      scheduler.stop()
      return tuck_ResultSingleton.code
  }
  return 1
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckStartActor(drain_tuck_Result)
	mainRc := tuck_main()
	rt.tuckRun()
	os.exit(mainRc)
}
