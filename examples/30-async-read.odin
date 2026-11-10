#+feature dynamic-literals using-stmt
package main

import "core:os"
import rt "./tuckrt"
import tuckˑmodˑshapes_30_async_read "./mod_shapes_30_async_read"
import tuckˑmodˑtime "./mod_time"

openSource :: proc(ms: int) -> tuckˑmodˑshapes_30_async_read.TRec_fd(int) {
	raw := rt.openSource(ms)
	return tuckˑmodˑshapes_30_async_read.TRec_fd(int){fd = raw.fd}
}


TuckFˑtuckˑtaskˑreadOrGiveUp :: struct {
	tuckHdr: rt.TuckFrameHdr,
	tuckRes: ^rt.TuckSlot(tuckˑmodˑshapes_30_async_read.TRec_code(int)),
	tuckDest: ^tuckˑmodˑshapes_30_async_read.TRec_code(int),
	fd: int,
	tuckˑvˑcode: int,
}

TuckNewˑtuckˑtaskˑreadOrGiveUp :: proc(tuckAt: ^TuckFˑtuckˑtaskˑreadOrGiveUp, tuckRes: ^rt.TuckSlot(tuckˑmodˑshapes_30_async_read.TRec_code(int)), tuckDest: ^tuckˑmodˑshapes_30_async_read.TRec_code(int), fd: int) -> ^TuckFˑtuckˑtaskˑreadOrGiveUp {
	f := tuckAt
	if f == nil { f = new(TuckFˑtuckˑtaskˑreadOrGiveUp) } else { f^ = {}; f.tuckHdr.embedded = true }
	f.tuckHdr.stage = TuckSˑtuckˑtaskˑreadOrGiveUpˑ0
	f.tuckRes = tuckRes
	f.tuckDest = tuckDest
	f.fd = fd
	return f
}

TuckRetˑtuckˑtaskˑreadOrGiveUp :: proc(tuckF: ^TuckFˑtuckˑtaskˑreadOrGiveUp, v: tuckˑmodˑshapes_30_async_read.TRec_code(int)) -> rt.TuckHop {
	rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v)
	TuckExitˑtuckˑtaskˑreadOrGiveUp(tuckF)
	h := rt.tuckSlReturnHop(&tuckF.tuckHdr)
	if !tuckF.tuckHdr.embedded do free(tuckF)
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
  if rt.tuckAwaitReadOrTimeout(fd, int(tuckˑmodˑtime.tuckˑfnˑms(u32(100)))) {
    tuckˑvˑcode = 1
  } else {
    tuckˑvˑcode = 2
  }
}

TuckSˑtuckˑtaskˑreadOrGiveUpˑ1 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑreadOrGiveUp)(env)
  using tuckF
  return TuckRetˑtuckˑtaskˑreadOrGiveUp(tuckF, tuckˑmodˑshapes_30_async_read.TRec_code(int){code = tuckˑvˑcode})
}

TuckExitˑtuckˑtaskˑreadOrGiveUp :: proc(tuckF: ^TuckFˑtuckˑtaskˑreadOrGiveUp) {
  using tuckF
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑsrc := openSource(5)
  slot0: rt.TuckSlot(tuckˑmodˑshapes_30_async_read.TRec_code(int))
  slot0F: TuckFˑtuckˑtaskˑreadOrGiveUp
  rt.tuckSlReady(&TuckNewˑtuckˑtaskˑreadOrGiveUp(&slot0F, &slot0, nil, tuckˑvˑsrc.fd).tuckHdr)
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
