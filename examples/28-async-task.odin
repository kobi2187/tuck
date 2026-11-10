#+feature dynamic-literals using-stmt
package main

import "core:os"
import rt "./tuckrt"

TRec_v :: struct ($T_v: typeid) {
	v: T_v,
}

TRec_r :: struct ($T_r: typeid) {
	r: T_r,
}

tuckˑfnˑstepIo :: proc (n: int) -> TRec_v(int) {
  return TRec_v(int){v = n}
}

TuckFˑtuckˑtaskˑcompute :: struct {
	tuckHdr: rt.TuckFrameHdr,
	tuckRes: ^rt.TuckSlot(TRec_r(int)),
	tuckDest: ^TRec_r(int),
	base: int,
	tuckˑvˑa: TRec_v(int),
	tuckˑvˑb: TRec_v(int),
}

TuckNewˑtuckˑtaskˑcompute :: proc(tuckRes: ^rt.TuckSlot(TRec_r(int)), tuckDest: ^TRec_r(int), base: int) -> ^TuckFˑtuckˑtaskˑcompute {
	f := new(TuckFˑtuckˑtaskˑcompute)
	f.tuckHdr.stage = TuckSˑtuckˑtaskˑcomputeˑ0
	f.tuckRes = tuckRes
	f.tuckDest = tuckDest
	f.base = base
	return f
}

TuckRetˑtuckˑtaskˑcompute :: proc(tuckF: ^TuckFˑtuckˑtaskˑcompute, v: TRec_r(int)) -> rt.TuckHop {
	rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v)
	TuckExitˑtuckˑtaskˑcompute(tuckF)
	h := rt.tuckSlReturnHop(&tuckF.tuckHdr)
	free(tuckF)
	return h
}

TuckSˑtuckˑtaskˑcomputeˑ0 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑcompute)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑcomputeˑ1)
}

TuckSˑtuckˑtaskˑcomputeˑ1 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑcompute)(env)
  using tuckF
  tuckˑvˑa = tuckˑfnˑstepIo(base)
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑcomputeˑ2)
}

TuckSˑtuckˑtaskˑcomputeˑ2 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑcompute)(env)
  using tuckF
  tuckˑvˑb = tuckˑfnˑstepIo(base)
  return TuckRetˑtuckˑtaskˑcompute(tuckF, TRec_r(int){r = (tuckˑvˑa.v + tuckˑvˑb.v)})
}

TuckExitˑtuckˑtaskˑcompute :: proc(tuckF: ^TuckFˑtuckˑtaskˑcompute) {
  using tuckF
}

tuckˑfnˑmain :: proc () -> int {
  slot0: rt.TuckSlot(TRec_r(int))
  rt.tuckSlReady(&TuckNewˑtuckˑtaskˑcompute(&slot0, nil, 21).tuckHdr)
  tuckˑvˑres := rt.tuckSlAwaitMain(&slot0)
  return tuckˑvˑres.r
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
