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

Env_tuckˑtaskˑreadOrGiveUp :: struct {
	fd: int,
	slot: ^rt.TuckAsyncResult(TRec_code(int)),
}

wrap_tuckˑtaskˑreadOrGiveUp :: proc() {
	e := (^Env_tuckˑtaskˑreadOrGiveUp)(context.user_ptr)
	e.slot.value = tuckˑtaskˑreadOrGiveUp(e.fd)
	e.slot.done = true
	free(e)
}

openSource :: proc(ms: int) -> TRec_fd(int) {
	raw := rt.openSource(ms)
	return TRec_fd(int){fd = raw.fd}
}


tuckˑtaskˑreadOrGiveUp :: proc(fd: int) -> TRec_code(int) {
  if rt.tuckAwaitReadOrTimeout(fd, int(time.tuckˑfnˑms(u32(30)))) {
    return TRec_code(int){code = 1}
  } else {
    return TRec_code(int){code = 2}
  }
  return {}
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑsrc := openSource(500)
  env0 := new(Env_tuckˑtaskˑreadOrGiveUp)
  env0.fd = tuckˑvˑsrc.fd
  slot0 := rt.newAsyncResult(TRec_code(int))
  env0.slot = slot0
  savedCtx0 := context.user_ptr
  context.user_ptr = env0
  rt.tuckSpawn(wrap_tuckˑtaskˑreadOrGiveUp)
  context.user_ptr = savedCtx0
  tuckˑvˑr := rt.awaitResult(slot0)
  return tuckˑvˑr.code
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	mainRc := tuckˑfnˑmain()
	rt.tuckRun()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
