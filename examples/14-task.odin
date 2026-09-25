#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"
import http "./mod_http"

TRec_feed :: struct ($T_feed: typeid) {
	feed: T_feed,
}

tuck_type_Feed :: struct {
	episodes: int,
}

tuck_fn_parse :: proc(payload: $T) -> TRec_feed(tuck_type_Feed) {
	fmt.println("TUCK PENDING: tuck_fn_parse invoked (not implemented)")
	return {}
}


tuck_fn_fetchFeed :: proc(url: string) -> rt.TuckResult(TRec_feed(tuck_type_Feed)) {
  tuck_resp := http.tuck_fn_get(url)
  if (tuck_resp.status == .Ok) {
      return rt.tok(tuck_fn_parse(tuck_resp.value.body))
  }
  return rt.terr(TRec_feed(tuck_type_Feed), u16(tuck_resp.err))
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	rt.tuckRun()
	rt.tuckTrackCheck()
}
