#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import tuckˑmodˑshapes_29_task_timeout "./mod_shapes_29_task_timeout"
import tuckˑmodˑtime "./mod_time"

Env_tuckˑtaskˑreadOrGiveUp :: struct {
	fd: int,
	slot: ^rt.TuckAsyncResult(tuckˑmodˑshapes_29_task_timeout.TRec_code(int)),
}

wrap_tuckˑtaskˑreadOrGiveUp :: proc() {
	e := (^Env_tuckˑtaskˑreadOrGiveUp)(context.user_ptr)
	e.slot.value = tuckˑtaskˑreadOrGiveUp(e.fd)
	e.slot.done = true
	free(e)
}

openSource :: proc(ms: int) -> tuckˑmodˑshapes_29_task_timeout.TRec_fd(int) {
	raw := rt.openSource(ms)
	return tuckˑmodˑshapes_29_task_timeout.TRec_fd(int){fd = raw.fd}
}


tuckˑtaskˑreadOrGiveUp :: proc(fd: int) -> tuckˑmodˑshapes_29_task_timeout.TRec_code(int) {
  tuckˑvˑcode := 0
  if rt.tuckAwaitReadOrTimeout(fd, int(tuckˑmodˑtime.tuckˑfnˑms(u32(30)))) {
    tuckˑvˑcode = 1
  } else {
    tuckˑvˑcode = 2
  }
  return tuckˑmodˑshapes_29_task_timeout.TRec_code(int){code = tuckˑvˑcode}
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑsrc := openSource(500)
  env0 := new(Env_tuckˑtaskˑreadOrGiveUp)
  env0.fd = tuckˑvˑsrc.fd
  slot0 := rt.newAsyncResult(tuckˑmodˑshapes_29_task_timeout.TRec_code(int))
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
