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

Env_tuck_compute :: struct {
	base: int,
	slot: ^rt.TuckAsyncResult(TRec_r(int)),
}

wrap_tuck_compute :: proc() {
	e := (^Env_tuck_compute)(context.user_ptr)
	e.slot.value = tuck_compute(e.base)
	e.slot.done = true
	free(e)
}

tuck_stepIo :: proc (n: int) -> TRec_v(int) {
  return TRec_v(int){v = n}
}

tuck_compute :: proc(base: int) -> TRec_r(int) {
  tuck_a := tuck_stepIo(base)
  tuck_b := tuck_stepIo(base)
  return TRec_r(int){r = (tuck_a.v + tuck_b.v)}
}

tuck_main :: proc () -> int {
  env0 := new(Env_tuck_compute)
  env0.base = 21
  slot0 := rt.newAsyncResult(TRec_r(int))
  env0.slot = slot0
  savedCtx0 := context.user_ptr
  context.user_ptr = env0
  rt.tuckSpawn(wrap_tuck_compute)
  context.user_ptr = savedCtx0
  tuck_res := rt.awaitResult(slot0)
  return tuck_res.r
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	mainRc := tuck_main()
	rt.tuckRun()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
