package main

import "core:os"
import rt "./tuckrt"

TRec_code_CEC9 :: struct {
	code: int,
}

tuck_readOrGiveUp :: proc(fd: int) -> TRec_code_CEC9 {
  return /* on select: not yet lowered for Odin */
}

tuck_main :: proc () -> int {
  src := openSource(5)
  r := tuck_readOrGiveUp(src.fd)
  return r.code
}

main :: proc() {
	rt.tuckAsyncInit()
	mainRc := tuck_main()
	rt.tuckRun()
	os.exit(mainRc)
}
