#+feature dynamic-literals using-stmt
package main

import "core:os"
import rt "./tuckrt"
import tuckˑmodˑshapes_29_task_timeout "./mod_shapes_29_task_timeout"
import tuckˑmodˑtime "./mod_time"

openSource :: proc(ms: int) -> tuckˑmodˑshapes_29_task_timeout.TRec_fd(int) {
	raw := rt.openSource(ms)
	return tuckˑmodˑshapes_29_task_timeout.TRec_fd(int){fd = raw.fd}
}


TuckFˑtuckˑtaskˑreadOrGiveUp :: struct {
	tuckHdr: rt.TuckFrameHdr,
	tuckRes: ^rt.TuckSlot(tuckˑmodˑshapes_29_task_timeout.TRec_code(int)),
	tuckDest: ^tuckˑmodˑshapes_29_task_timeout.TRec_code(int),
	fd: int,
	tuckˑvˑcode: int,
}

TuckNewˑtuckˑtaskˑreadOrGiveUp :: proc(tuckRes: ^rt.TuckSlot(tuckˑmodˑshapes_29_task_timeout.TRec_code(int)), tuckDest: ^tuckˑmodˑshapes_29_task_timeout.TRec_code(int), fd: int) -> ^TuckFˑtuckˑtaskˑreadOrGiveUp {
	f := new(TuckFˑtuckˑtaskˑreadOrGiveUp)
	f.tuckHdr.stage = TuckSˑtuckˑtaskˑreadOrGiveUpˑ0
	f.tuckRes = tuckRes
	f.tuckDest = tuckDest
	f.fd = fd
	return f
}

TuckRetˑtuckˑtaskˑreadOrGiveUp :: proc(tuckF: ^TuckFˑtuckˑtaskˑreadOrGiveUp, v: tuckˑmodˑshapes_29_task_timeout.TRec_code(int)) -> rt.TuckHop {
	rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v)
	TuckExitˑtuckˑtaskˑreadOrGiveUp(tuckF)
	h := rt.tuckSlReturnHop(&tuckF.tuckHdr)
	free(tuckF)
	return h
}

TuckSˑtuckˑtaskˑreadOrGiveUpˑ0 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑreadOrGiveUp)(env)
  using tuckF
  tuckˑvˑcode = 0
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑreadOrGiveUpˑ1, TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0)
}

TuckIOˑtuckˑtaskˑreadOrGiveUpˑ0 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑreadOrGiveUp)(env)
  using tuckF
  if rt.tuckAwaitReadOrTimeout(fd, int(tuckˑmodˑtime.tuckˑfnˑms(u32(30)))) {
    tuckˑvˑcode = 1
  } else {
    tuckˑvˑcode = 2
  }
}

TuckSˑtuckˑtaskˑreadOrGiveUpˑ1 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑreadOrGiveUp)(env)
  using tuckF
  return TuckRetˑtuckˑtaskˑreadOrGiveUp(tuckF, tuckˑmodˑshapes_29_task_timeout.TRec_code(int){code = tuckˑvˑcode})
}

TuckExitˑtuckˑtaskˑreadOrGiveUp :: proc(tuckF: ^TuckFˑtuckˑtaskˑreadOrGiveUp) {
  using tuckF
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑsrc := openSource(500)
  slot0: rt.TuckSlot(tuckˑmodˑshapes_29_task_timeout.TRec_code(int))
  rt.tuckSlReady(&TuckNewˑtuckˑtaskˑreadOrGiveUp(&slot0, nil, tuckˑvˑsrc.fd).tuckHdr)
  tuckˑvˑr := rt.tuckSlAwaitMain(&slot0)
  return tuckˑvˑr.code
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	mainRc := tuckˑfnˑmain()
	rt.tuckSlRunAll()
	rt.tuckRun()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
