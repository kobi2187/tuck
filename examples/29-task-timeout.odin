package main

import "core:os"
import rt "./tuckrt"
import time "./mod_time"

TRec_fd_A79D :: struct {
	fd: int,
}

TRec_code_CEC9 :: struct {
	code: int,
}

Env_tuck_readOrGiveUp :: struct {
	fd: int,
	slot: ^rt.TuckAsyncResult(TRec_code_CEC9),
}

wrap_tuck_readOrGiveUp :: proc() {
	e := (^Env_tuck_readOrGiveUp)(context.user_ptr)
	e.slot.value = tuck_readOrGiveUp(e.fd)
	e.slot.done = true
	free(e)
}

openSource :: proc(ms: int) -> TRec_fd_A79D {
	raw := rt.openSource(ms)
	return TRec_fd_A79D{fd = raw.fd}
}


tuck_readOrGiveUp :: proc(fd: int) -> TRec_code_CEC9 {
  if rt.tuckAwaitReadOrTimeout(fd, int(time.tuck_ms(30))) {
    return TRec_code_CEC9{code = 1}
  } else {
    return TRec_code_CEC9{code = 2}
  }
  return {}
}

tuck_main :: proc () -> int {
  src := openSource(500)
  env0 := new(Env_tuck_readOrGiveUp)
  env0.fd = src.fd
  slot0 := rt.newAsyncResult(TRec_code_CEC9)
  env0.slot = slot0
  savedCtx0 := context.user_ptr
  context.user_ptr = env0
  rt.tuckSpawn(wrap_tuck_readOrGiveUp)
  context.user_ptr = savedCtx0
  r := rt.awaitResult(slot0)
  return r.code
}

main :: proc() {
	rt.tuckAsyncInit()
	mainRc := tuck_main()
	rt.tuckRun()
	os.exit(mainRc)
}
