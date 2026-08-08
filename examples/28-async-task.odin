package main

import "core:os"
import rt "./tuckrt"

TRec_v_9DF2 :: struct {
	v: int,
}

TRec_r_5BC4 :: struct {
	r: int,
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
  res := tuck_compute(21)
  return res.r
}

main :: proc() {
	rt.tuckAsyncInit()
	mainRc := tuck_main()
	rt.tuckRun()
	os.exit(mainRc)
}
