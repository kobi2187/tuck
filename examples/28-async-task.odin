package main

import "core:os"
import rt "./tuckrt"

TRec_v_9DF2 :: struct {
	v: int,
}

TRec_r_5BC4 :: struct {
	r: int,
}

Env_tuck_compute :: struct {
	base: int,
	slot: ^rt.TuckAsyncResult(TRec_r_5BC4),
}

wrap_tuck_compute :: proc() {
	e := (^Env_tuck_compute)(context.user_ptr)
	e.slot.value = tuck_compute(e.base)
	e.slot.done = true
	free(e)
}

tuck_stepIo :: proc (n: int) -> TRec_v_9DF2 {
  return TRec_v_9DF2{v = n}
}

tuck_compute :: proc(base: int) -> TRec_r_5BC4 {
  a := tuck_stepIo(base)
  b := tuck_stepIo(base)
  return TRec_r_5BC4{r = (a.v + b.v)}
}

tuck_main :: proc () -> int {
  env0 := new(Env_tuck_compute)
  env0.base = 21
  slot0 := rt.newAsyncResult(TRec_r_5BC4)
  env0.slot = slot0
  savedCtx0 := context.user_ptr
  context.user_ptr = env0
  rt.tuckSpawn(wrap_tuck_compute)
  context.user_ptr = savedCtx0
  res := rt.awaitResult(slot0)
  return res.r
}

main :: proc() {
	rt.tuckAsyncInit()
	mainRc := tuck_main()
	rt.tuckRun()
	os.exit(mainRc)
}
