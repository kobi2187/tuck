#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"
import net "./mod_net"

tuck_ResultMsgKind :: enum { msgPut }
tuck_ResultMsg :: struct {
	tuckTag: tuck_ResultMsgKind,
	c: int,
}
tuck_Result :: struct {
	code: int,
	ready: bool,
	mailbox: rt.Mailbox(tuck_ResultMsg, 8),
}

tuck_ResultSingleton: tuck_Result

handleMsg_tuck_Result :: proc(self: ^tuck_Result, msg: tuck_ResultMsg) {
	switch msg.tuckTag {
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
	_ = rt.enqueue(&self.mailbox, tuck_ResultMsg{tuckTag = .msgPut, c = c})
}

tuck_serve :: proc(lfd: int) {
  tuck_c := net.accept(lfd)
  if (tuck_c.status == .Ok) {
      _ = net.recv(tuck_c.value.fd, 256)
      _ = net.send(tuck_c.value.fd, "pong")
      net.close(tuck_c.value.fd)
  }
  return
}

tuck_client :: proc(port: int) {
  tuck_c := net.connect("127.0.0.1", port)
  if (tuck_c.status == .Ok) {
      _ = net.send(tuck_c.value.fd, "ping")
      tuck_r := net.recv(tuck_c.value.fd, 256)
      net.close(tuck_c.value.fd)
      if (tuck_r.status == .Ok) {
          if (tuck_r.value.data == "pong") {
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
  tuck_l := net.listen(34593)
  if (tuck_l.status == .Ok) {
      tuck_serve(tuck_l.value.fd)
      tuck_client(34593)
      scheduler.waitUntil(tuck_done)
      net.close(tuck_l.value.fd)
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
