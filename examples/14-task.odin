package main

import "core:fmt"
import rt "./tuckrt"
import http "./mod_http"

TRec_feed_A1A6 :: struct {
	feed: tuck_Feed,
}

tuck_Feed :: struct {
	episodes: int,
}

tuck_parse :: proc(payload: $T) -> TRec_feed_A1A6 {
	fmt.println("TUCK PENDING: tuck_parse invoked (not implemented)")
	return {}
}


tuck_fetchFeed :: proc(url: string) -> rt.TuckResult(TRec_feed_A1A6) {
  resp := http.tuck_get(url)
  if (resp.status == .Ok) {
      return rt.tok(tuck_parse(resp.value.body))
  }
  return rt.terr(TRec_feed_A1A6, u16(resp.err))
}

main :: proc() {
	rt.tuckAsyncInit()
	rt.tuckRun()
}
