#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import scheduler "./mod_scheduler"
import net "./mod_net"

tuckˑactorˑResultMsgKind :: enum { msgPut }
tuckˑactorˑResultMsg :: struct {
	tuckTag: tuckˑactorˑResultMsgKind,
	c: int,
}
tuckˑactorˑResult :: struct {
	code: int,
	ready: bool,
	mailbox: rt.Mailbox(tuckˑactorˑResultMsg, 8),
}

tuckˑactorˑResultSingleton: tuckˑactorˑResult

handleMsg_tuckˑactorˑResult :: proc(self: ^tuckˑactorˑResult, msg: tuckˑactorˑResultMsg) {
	switch msg.tuckTag {
	case .msgPut:
		c := msg.c
    self.code = c
    self.ready = true
	}
}

tuckˑactorˑResultSlot: rawptr

drain_tuckˑactorˑResult :: proc() -> bool {
	didWork := false
	batch, n := rt.takeBatch(&tuckˑactorˑResultSingleton.mailbox)
	for i in 0 ..< n {
		handleMsg_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, batch[i])
		rt.tuckCheckWaiters()
		didWork = true
	}
	return didWork
}

sendPut_tuckˑactorˑResult :: proc(self: ^tuckˑactorˑResult, c: int) {
	_ = rt.enqueue(&self.mailbox, tuckˑactorˑResultMsg{tuckTag = .msgPut, c = c})
	rt.tuckNotifySend(tuckˑactorˑResultSlot)
}

tuckˑtaskˑserve :: proc(lfd: int) {
  tuckˑvˑc := net.accept(lfd)
  if (tuckˑvˑc.status == .Ok) {
      _ = net.recv(tuckˑvˑc.value.fd, 256)
      _ = net.send(tuckˑvˑc.value.fd, "pong")
      net.close(tuckˑvˑc.value.fd)
  }
  return
}

tuckˑtaskˑclient :: proc(port: int) {
  tuckˑvˑc := net.connect("127.0.0.1", port)
  if (tuckˑvˑc.status == .Ok) {
      _ = net.send(tuckˑvˑc.value.fd, "ping")
      tuckˑvˑr := net.recv(tuckˑvˑc.value.fd, 256)
      net.close(tuckˑvˑc.value.fd)
      if (tuckˑvˑr.status == .Ok) {
          if (tuckˑvˑr.value.data == "pong") {
              sendPut_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, 42)
              return
          }
      }
      sendPut_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, 3)
      return
  }
  sendPut_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, 4)
  return
}

tuckˑfnˑdone :: proc () -> bool {
  return tuckˑactorˑResultSingleton.ready
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑl := net.listen(34593)
  if (tuckˑvˑl.status == .Ok) {
      tuckˑtaskˑserve(tuckˑvˑl.value.fd)
      tuckˑtaskˑclient(34593)
      rt.tuckWaitOn(tuckˑactorˑResultSlot, tuckˑfnˑdone)
      net.close(tuckˑvˑl.value.fd)
      scheduler.stop()
      return tuckˑactorˑResultSingleton.code
  }
  return 1
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑactorˑResultSingleton.code = 0
	tuckˑactorˑResultSingleton.ready = false
	rt.tuckAsyncInit()
	tuckˑactorˑResultSlot = rt.tuckStartActor(drain_tuckˑactorˑResult)
	mainRc := tuckˑfnˑmain()
	rt.tuckRun()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
