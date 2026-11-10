#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import tuckˑmodˑnet "./mod_net"
import tuckˑmodˑscheduler "./mod_scheduler"

SpawnEnv_tuckˑtaskˑserve :: struct {
	lfd: int,
}

spawn_tuckˑtaskˑserve :: proc() {
	e := (^SpawnEnv_tuckˑtaskˑserve)(context.user_ptr)
	tuckˑtaskˑserve(e.lfd)
	free(e)
}

SpawnEnv_tuckˑtaskˑclient :: struct {
	port: int,
}

spawn_tuckˑtaskˑclient :: proc() {
	e := (^SpawnEnv_tuckˑtaskˑclient)(context.user_ptr)
	tuckˑtaskˑclient(e.port)
	free(e)
}

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
	rt.sendWaiting(&self.mailbox, tuckˑactorˑResultMsg{tuckTag = .msgPut, c = c}, tuckˑactorˑResultSlot, "Result")
	rt.tuckNotifySend(tuckˑactorˑResultSlot)
}

tuckˑtaskˑserve :: proc(lfd: int) {
  tuckˑvˑc := tuckˑmodˑnet.accept(lfd)
  if (tuckˑvˑc.status == .Ok) {
      tuckOwnTmp1 := tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256)
      defer rt.tuckDrop(tuckOwnTmp1)
      _ = tuckOwnTmp1
      _ = tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "pong")
      tuckˑmodˑnet.close(tuckˑvˑc.value.fd)
  }
  return
}

tuckˑtaskˑclient :: proc(port: int) {
  tuckˑvˑc := tuckˑmodˑnet.connect("127.0.0.1", port)
  if (tuckˑvˑc.status == .Ok) {
      _ = tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "ping")
      tuckˑvˑr := tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256)
      defer rt.tuckDrop(tuckˑvˑr)
      tuckˑmodˑnet.close(tuckˑvˑc.value.fd)
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
  tuckˑvˑl := tuckˑmodˑnet.listen(34593)
  if (tuckˑvˑl.status == .Ok) {
      env0 := new(SpawnEnv_tuckˑtaskˑserve)
      env0.lfd = tuckˑvˑl.value.fd
      savedCtx0 := context.user_ptr
      context.user_ptr = env0
      rt.tuckSpawn(spawn_tuckˑtaskˑserve)
      context.user_ptr = savedCtx0
      env1 := new(SpawnEnv_tuckˑtaskˑclient)
      env1.port = 34593
      savedCtx1 := context.user_ptr
      context.user_ptr = env1
      rt.tuckSpawn(spawn_tuckˑtaskˑclient)
      context.user_ptr = savedCtx1
      rt.tuckWaitOn(tuckˑactorˑResultSlot, tuckˑfnˑdone)
      tuckˑmodˑnet.close(tuckˑvˑl.value.fd)
      tuckˑmodˑscheduler.stop()
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
