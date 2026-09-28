#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

TRec_v :: struct ($T_v: typeid) {
	v: T_v,
}

TRec_r :: struct ($T_r: typeid) {
	r: T_r,
}

Env_tuckˑtaskˑcompute :: struct {
	base: int,
	slot: ^rt.TuckAsyncResult(TRec_r(int)),
}

wrap_tuckˑtaskˑcompute :: proc() {
	e := (^Env_tuckˑtaskˑcompute)(context.user_ptr)
	e.slot.value = tuckˑtaskˑcompute(e.base)
	e.slot.done = true
	free(e)
}

tuckˑfnˑstepIo :: proc (n: int) -> TRec_v(int) {
  return TRec_v(int){v = n}
}

tuckˑtaskˑcompute :: proc(base: int) -> TRec_r(int) {
  tuckˑvˑa := tuckˑfnˑstepIo(base)
  tuckˑvˑb := tuckˑfnˑstepIo(base)
  return TRec_r(int){r = (tuckˑvˑa.v + tuckˑvˑb.v)}
}

tuckˑfnˑmain :: proc () -> int {
  env0 := new(Env_tuckˑtaskˑcompute)
  env0.base = 21
  slot0 := rt.newAsyncResult(TRec_r(int))
  env0.slot = slot0
  savedCtx0 := context.user_ptr
  context.user_ptr = env0
  rt.tuckSpawn(wrap_tuckˑtaskˑcompute)
  context.user_ptr = savedCtx0
  tuckˑvˑres := rt.awaitResult(slot0)
  return tuckˑvˑres.r
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	mainRc := tuckˑfnˑmain()
	rt.tuckRun()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
