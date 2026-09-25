#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"
import net "./mod_net"

tuck_type_ResultMsgKind :: enum { msgPut }
tuck_type_ResultMsg :: struct {
	tuckTag: tuck_type_ResultMsgKind,
	c: int,
}
tuck_type_Result :: struct {
	code: int,
	ready: bool,
	mailbox: rt.Mailbox(tuck_type_ResultMsg, 8),
}

tuck_type_ResultSingleton: tuck_type_Result

handleMsg_tuck_type_Result :: proc(self: ^tuck_type_Result, msg: tuck_type_ResultMsg) {
	switch msg.tuckTag {
	case .msgPut:
		c := msg.c
    self.code = c
    self.ready = true
	}
}

tuck_type_ResultSlot: rawptr

drain_tuck_type_Result :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuck_type_ResultSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuck_type_Result(&tuck_type_ResultSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendPut_tuck_type_Result :: proc(self: ^tuck_type_Result, c: int) {
	_ = rt.enqueue(&self.mailbox, tuck_type_ResultMsg{tuckTag = .msgPut, c = c})
	rt.tuckNotifySend(tuck_type_ResultSlot)
}

tuck_fn_serve :: proc(lfd: int) {
  tuck_c := net.accept(lfd)
  if (tuck_c.status == .Ok) {
      _ = net.recv(tuck_c.value.fd, 256)
      _ = net.send(tuck_c.value.fd, "pong")
      net.close(tuck_c.value.fd)
  }
  return
}

tuck_fn_client :: proc(port: int) {
  tuck_c := net.connect("127.0.0.1", port)
  if (tuck_c.status == .Ok) {
      _ = net.send(tuck_c.value.fd, "ping")
      tuck_r := net.recv(tuck_c.value.fd, 256)
      net.close(tuck_c.value.fd)
      if (tuck_r.status == .Ok) {
          if (tuck_r.value.data == "pong") {
              sendPut_tuck_type_Result(&tuck_type_ResultSingleton, 42)
              return
          }
      }
      sendPut_tuck_type_Result(&tuck_type_ResultSingleton, 3)
      return
  }
  sendPut_tuck_type_Result(&tuck_type_ResultSingleton, 4)
  return
}

tuck_fn_done :: proc () -> bool {
  return tuck_type_ResultSingleton.ready
}

tuck_fn_main :: proc () -> int {
  tuck_l := net.listen(34593)
  if (tuck_l.status == .Ok) {
      tuck_fn_serve(tuck_l.value.fd)
      tuck_fn_client(34593)
      rt.tuckWaitOn(tuck_type_ResultSlot, tuck_fn_done)
      net.close(tuck_l.value.fd)
      scheduler.stop()
      return tuck_type_ResultSingleton.code
  }
  return 1
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_type_ResultSingleton.code = 0
	tuck_type_ResultSingleton.ready = false
	rt.tuckAsyncInit()
	tuck_type_ResultSlot = rt.tuckStartActor(drain_tuck_type_Result)
	mainRc := tuck_fn_main()
	rt.tuckRun()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
