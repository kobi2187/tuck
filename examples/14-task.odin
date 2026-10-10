#+feature dynamic-literals
package main

import "core:fmt"
import rt "./tuckrt"
import http "./mod_http"

TRec_feed :: struct ($T_feed: typeid) {
	feed: T_feed,
}

TRec_body :: struct ($T_body: typeid) {
	body: T_body,
}

tuckG_2_copy :: proc(value: $G) -> G {
	return rt.tuckStrOwned(value)
}
tuckG_2_drop :: proc(value: $G) {
	delete(value)
}
tuckG_2_reset :: proc(value: ^$G) { tuckG_2_drop(value^); value^ = {} }


tuckG_1_copy :: proc(value: $G) -> G {
	out := value
	out.body = tuckG_2_copy(value.body)
	return out
}
tuckG_1_drop :: proc(value: $G) {
	tuckG_2_drop(value.body)
}
tuckG_1_reset :: proc(value: ^$G) { tuckG_1_drop(value^); value^ = {} }


tuckG_0_copy :: proc(value: $G) -> G {
	out := value
	if value.status == .Ok {
		out.value = tuckG_1_copy(value.value)
	} else { out.value = {} }
	return out
}
tuckG_0_drop :: proc(value: $G) {
	if value.status == .Ok { tuckG_1_drop(value.value) }
}
tuckG_0_reset :: proc(value: ^$G) { tuckG_0_drop(value^); value^ = {} }


tuckˑtypeˑFeed :: struct {
	episodes: int,
}

tuckˑfnˑparse :: proc(payload: $T) -> TRec_feed(tuckˑtypeˑFeed) {
	fmt.println("TUCK PENDING: parse invoked (not implemented)")
	return {}
}


tuckˑtaskˑfetchFeed :: proc(url: string) -> rt.TuckResult(TRec_feed(tuckˑtypeˑFeed)) {
	url := url
  tuckˑvˑresp := http.tuckˑfnˑget(url)
  defer tuckG_0_drop(tuckˑvˑresp)
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
