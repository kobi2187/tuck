#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"
import http "./mod_http"

TRec_feed :: struct ($T_feed: typeid) {
	feed: T_feed,
}

tuckˑtypeˑFeed :: struct {
	episodes: int,
}

tuckˑfnˑparse :: proc(payload: $T) -> TRec_feed(tuckˑtypeˑFeed) {
	fmt.println("TUCK PENDING: parse invoked (not implemented)")
	return {}
}


tuckˑtaskˑfetchFeed :: proc(url: string) -> rt.TuckResult(TRec_feed(tuckˑtypeˑFeed)) {
  tuckˑvˑresp := http.tuckˑfnˑget(url)
  if (tuckˑvˑresp.status == .Ok) {
      return rt.tok(tuckˑfnˑparse(tuckˑvˑresp.value.body))
  }
  return rt.terr(TRec_feed(tuckˑtypeˑFeed), u16(tuckˑvˑresp.err))
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	rt.tuckRun()
	rt.tuckTrackCheck()
}
