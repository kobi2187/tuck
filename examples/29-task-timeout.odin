#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import time "./mod_time"

TRec_fd :: struct ($T_fd: typeid) {
	fd: T_fd,
}

TRec_code :: struct ($T_code: typeid) {
	code: T_code,
}

Env_tuck_fn_readOrGiveUp :: struct {
	fd: int,
	slot: ^rt.TuckAsyncResult(TRec_code(int)),
}

wrap_tuck_fn_readOrGiveUp :: proc() {
	e := (^Env_tuck_fn_readOrGiveUp)(context.user_ptr)
	e.slot.value = tuck_fn_readOrGiveUp(e.fd)
	e.slot.done = true
	free(e)
}

openSource :: proc(ms: int) -> TRec_fd(int) {
	raw := rt.openSource(ms)
	return TRec_fd(int){fd = raw.fd}
}


tuck_fn_readOrGiveUp :: proc(fd: int) -> TRec_code(int) {
  if rt.tuckAwaitReadOrTimeout(fd, int(time.tuck_fn_ms(u32(30)))) {
    return TRec_code(int){code = 1}
  } else {
    return TRec_code(int){code = 2}
  }
  return {}
}

tuck_fn_main :: proc () -> int {
  tuck_src := openSource(500)
  env0 := new(Env_tuck_fn_readOrGiveUp)
  env0.fd = tuck_src.fd
  slot0 := rt.newAsyncResult(TRec_code(int))
  env0.slot = slot0
  savedCtx0 := context.user_ptr
  context.user_ptr = env0
  rt.tuckSpawn(wrap_tuck_fn_readOrGiveUp)
  context.user_ptr = savedCtx0
  tuck_r := rt.awaitResult(slot0)
  return tuck_r.code
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	mainRc := tuck_fn_main()
	rt.tuckRun()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
