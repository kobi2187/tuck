#+feature dynamic-literals using-stmt
package main

import "core:os"
import rt "./tuckrt"
import tuckˑmodˑnet "./mod_net"
import tuckˑmodˑscheduler "./mod_scheduler"
import tuckˑmodˑshapes_42_net_echo "./mod_shapes_42_net_echo"

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

TuckFˑtuckˑtaskˑserve :: struct {
	tuckHdr: rt.TuckFrameHdr,
	tuckRes: ^rt.TuckSlot(bool),
	tuckDest: ^bool,
	lfd: int,
	tuckˑvˑc: rt.TuckResult(tuckˑmodˑshapes_42_net_echo.TRec_fd(int)),
	tuckOwnTmp1: rt.TuckResult(tuckˑmodˑshapes_42_net_echo.TRec_data(string)),
	tuckDefer0: bool,
}

TuckNewˑtuckˑtaskˑserve :: proc(tuckRes: ^rt.TuckSlot(bool), tuckDest: ^bool, lfd: int) -> ^TuckFˑtuckˑtaskˑserve {
	f := new(TuckFˑtuckˑtaskˑserve)
	f.tuckHdr.stage = TuckSˑtuckˑtaskˑserveˑ0
	f.tuckRes = tuckRes
	f.tuckDest = tuckDest
	f.lfd = lfd
	return f
}

TuckRetˑtuckˑtaskˑserve :: proc(tuckF: ^TuckFˑtuckˑtaskˑserve) -> rt.TuckHop {
	if tuckF.tuckRes != nil do rt.tuckSlComplete(tuckF.tuckRes, true)
	TuckExitˑtuckˑtaskˑserve(tuckF)
	h := rt.tuckSlReturnHop(&tuckF.tuckHdr)
	free(tuckF)
	return h
}

TuckSˑtuckˑtaskˑserveˑ0 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ1)
}

TuckSˑtuckˑtaskˑserveˑ1 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ2, TuckIOˑtuckˑtaskˑserveˑ0)
}

TuckIOˑtuckˑtaskˑserveˑ0 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  tuckˑvˑc = tuckˑmodˑnet.accept(lfd)
}

TuckSˑtuckˑtaskˑserveˑ2 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  if (tuckˑvˑc.status == .Ok) do return TuckSˑtuckˑtaskˑserveˑ4(env)
  return TuckSˑtuckˑtaskˑserveˑ11(env)
}

TuckSˑtuckˑtaskˑserveˑ3 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return TuckRetˑtuckˑtaskˑserve(tuckF)
}

TuckSˑtuckˑtaskˑserveˑ4 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ5)
}

TuckSˑtuckˑtaskˑserveˑ5 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ6, TuckIOˑtuckˑtaskˑserveˑ1)
}

TuckIOˑtuckˑtaskˑserveˑ1 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  tuckOwnTmp1 = tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256)
}

TuckSˑtuckˑtaskˑserveˑ6 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  tuckDefer0 = true
  _ = tuckOwnTmp1
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ7)
}

TuckSˑtuckˑtaskˑserveˑ7 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ8, TuckIOˑtuckˑtaskˑserveˑ2)
}

TuckIOˑtuckˑtaskˑserveˑ2 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  _ = tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "pong")
}

TuckSˑtuckˑtaskˑserveˑ8 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ9)
}

TuckSˑtuckˑtaskˑserveˑ9 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑserveˑ10, TuckIOˑtuckˑtaskˑserveˑ3)
}

TuckIOˑtuckˑtaskˑserveˑ3 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  tuckˑmodˑnet.close(tuckˑvˑc.value.fd)
}

TuckSˑtuckˑtaskˑserveˑ10 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  TuckXˑtuckˑtaskˑserveˑ1(tuckF)
  return TuckSˑtuckˑtaskˑserveˑ3(env)
}

TuckSˑtuckˑtaskˑserveˑ11 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑserve)(env)
  using tuckF
  return TuckSˑtuckˑtaskˑserveˑ3(env)
}

TuckExitˑtuckˑtaskˑserve :: proc(tuckF: ^TuckFˑtuckˑtaskˑserve) {
  using tuckF
  if tuckDefer0 {
    rt.tuckDrop(tuckOwnTmp1)
    tuckDefer0 = false
  }
}
TuckXˑtuckˑtaskˑserveˑ1 :: proc(tuckF: ^TuckFˑtuckˑtaskˑserve) {
  using tuckF
  if tuckDefer0 {
    rt.tuckDrop(tuckOwnTmp1)
    tuckDefer0 = false
  }
}

TuckFˑtuckˑtaskˑclient :: struct {
	tuckHdr: rt.TuckFrameHdr,
	tuckRes: ^rt.TuckSlot(bool),
	tuckDest: ^bool,
	port: int,
	tuckˑvˑc: rt.TuckResult(tuckˑmodˑshapes_42_net_echo.TRec_fd(int)),
	tuckˑvˑr: rt.TuckResult(tuckˑmodˑshapes_42_net_echo.TRec_data(string)),
	tuckDefer0: bool,
}

TuckNewˑtuckˑtaskˑclient :: proc(tuckRes: ^rt.TuckSlot(bool), tuckDest: ^bool, port: int) -> ^TuckFˑtuckˑtaskˑclient {
	f := new(TuckFˑtuckˑtaskˑclient)
	f.tuckHdr.stage = TuckSˑtuckˑtaskˑclientˑ0
	f.tuckRes = tuckRes
	f.tuckDest = tuckDest
	f.port = port
	return f
}

TuckRetˑtuckˑtaskˑclient :: proc(tuckF: ^TuckFˑtuckˑtaskˑclient) -> rt.TuckHop {
	if tuckF.tuckRes != nil do rt.tuckSlComplete(tuckF.tuckRes, true)
	TuckExitˑtuckˑtaskˑclient(tuckF)
	h := rt.tuckSlReturnHop(&tuckF.tuckHdr)
	free(tuckF)
	return h
}

TuckSˑtuckˑtaskˑclientˑ0 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ1)
}

TuckSˑtuckˑtaskˑclientˑ1 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ2, TuckIOˑtuckˑtaskˑclientˑ0)
}

TuckIOˑtuckˑtaskˑclientˑ0 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  tuckˑvˑc = tuckˑmodˑnet.connect("127.0.0.1", port)
}

TuckSˑtuckˑtaskˑclientˑ2 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  if (tuckˑvˑc.status == .Ok) do return TuckSˑtuckˑtaskˑclientˑ4(env)
  return TuckSˑtuckˑtaskˑclientˑ19(env)
}

TuckSˑtuckˑtaskˑclientˑ3 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ20, TuckIOˑtuckˑtaskˑclientˑ6)
}

TuckIOˑtuckˑtaskˑclientˑ6 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  sendPut_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, 4)
}

TuckSˑtuckˑtaskˑclientˑ4 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ5)
}

TuckSˑtuckˑtaskˑclientˑ5 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ6, TuckIOˑtuckˑtaskˑclientˑ1)
}

TuckIOˑtuckˑtaskˑclientˑ1 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  _ = tuckˑmodˑnet.send(tuckˑvˑc.value.fd, "ping")
}

TuckSˑtuckˑtaskˑclientˑ6 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ7)
}

TuckSˑtuckˑtaskˑclientˑ7 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ8, TuckIOˑtuckˑtaskˑclientˑ2)
}

TuckIOˑtuckˑtaskˑclientˑ2 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  tuckˑvˑr = tuckˑmodˑnet.recv(tuckˑvˑc.value.fd, 256)
}

TuckSˑtuckˑtaskˑclientˑ8 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  tuckDefer0 = true
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ9)
}

TuckSˑtuckˑtaskˑclientˑ9 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ10, TuckIOˑtuckˑtaskˑclientˑ3)
}

TuckIOˑtuckˑtaskˑclientˑ3 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  tuckˑmodˑnet.close(tuckˑvˑc.value.fd)
}

TuckSˑtuckˑtaskˑclientˑ10 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  if (tuckˑvˑr.status == .Ok) do return TuckSˑtuckˑtaskˑclientˑ12(env)
  return TuckSˑtuckˑtaskˑclientˑ17(env)
}

TuckSˑtuckˑtaskˑclientˑ11 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ18, TuckIOˑtuckˑtaskˑclientˑ5)
}

TuckIOˑtuckˑtaskˑclientˑ5 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  sendPut_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, 3)
}

TuckSˑtuckˑtaskˑclientˑ12 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  if (tuckˑvˑr.value.data == "pong") do return TuckSˑtuckˑtaskˑclientˑ14(env)
  return TuckSˑtuckˑtaskˑclientˑ16(env)
}

TuckSˑtuckˑtaskˑclientˑ13 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckSˑtuckˑtaskˑclientˑ11(env)
}

TuckSˑtuckˑtaskˑclientˑ14 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑclientˑ15, TuckIOˑtuckˑtaskˑclientˑ4)
}

TuckIOˑtuckˑtaskˑclientˑ4 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  sendPut_tuckˑactorˑResult(&tuckˑactorˑResultSingleton, 42)
}

TuckSˑtuckˑtaskˑclientˑ15 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckRetˑtuckˑtaskˑclient(tuckF)
}

TuckSˑtuckˑtaskˑclientˑ16 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckSˑtuckˑtaskˑclientˑ13(env)
}

TuckSˑtuckˑtaskˑclientˑ17 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckSˑtuckˑtaskˑclientˑ11(env)
}

TuckSˑtuckˑtaskˑclientˑ18 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckRetˑtuckˑtaskˑclient(tuckF)
}

TuckSˑtuckˑtaskˑclientˑ19 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckSˑtuckˑtaskˑclientˑ3(env)
}

TuckSˑtuckˑtaskˑclientˑ20 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑclient)(env)
  using tuckF
  return TuckRetˑtuckˑtaskˑclient(tuckF)
}

TuckExitˑtuckˑtaskˑclient :: proc(tuckF: ^TuckFˑtuckˑtaskˑclient) {
  using tuckF
  if tuckDefer0 {
    rt.tuckDrop(tuckˑvˑr)
    tuckDefer0 = false
  }
}
TuckXˑtuckˑtaskˑclientˑ1 :: proc(tuckF: ^TuckFˑtuckˑtaskˑclient) {
  using tuckF
  if tuckDefer0 {
    rt.tuckDrop(tuckˑvˑr)
    tuckDefer0 = false
  }
}

tuckˑfnˑdone :: proc () -> bool {
  return tuckˑactorˑResultSingleton.ready
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑl := tuckˑmodˑnet.listen(34593)
  if (tuckˑvˑl.status == .Ok) {
      rt.tuckSlReady(&TuckNewˑtuckˑtaskˑserve(nil, nil, tuckˑvˑl.value.fd).tuckHdr)
      rt.tuckSlReady(&TuckNewˑtuckˑtaskˑclient(nil, nil, 34593).tuckHdr)
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
	tuckˑactorˑResultSlot = rt.tuckStartActorFrame(drain_tuckˑactorˑResult)
	mainRc := tuckˑfnˑmain()
	rt.tuckSlRunAll()
	rt.tuckRun()
	rt.tuckDrainActors()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
