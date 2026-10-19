#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"
import tuckˑmodˑhttp "./mod_http"
import tuckˑmodˑshapes_14_task "./mod_shapes_14_task"

tuckˑtypeˑFeed :: struct {
	episodes: int,
}

tuckˑfnˑparse :: proc(payload: $T) -> tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed) {
	fmt.println("TUCK PENDING: parse invoked (not implemented)")
	return {}
}


tuckˑtaskˑfetchFeed :: proc(url: string) -> rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed)) {
  tuckˑvˑresp := tuckˑmodˑhttp.tuckˑfnˑget(url)
  defer rt.tuckDrop(tuckˑvˑresp)
  if (tuckˑvˑresp.status == .Ok) {
      return rt.tok(tuckˑfnˑparse(tuckˑvˑresp.value.body))
  }
  return rt.terr(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed), u16(tuckˑvˑresp.err))
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	rt.tuckRun()
	rt.tuckTrackCheck()
}
