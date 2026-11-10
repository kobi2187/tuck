#+feature dynamic-literals using-stmt
package main

import "core:fmt"
import rt "./tuckrt"
import tuckˑmodˑhttp "./mod_http"
import tuckˑmodˑshapes_14_task "./mod_shapes_14_task"

tuckˑtypeˑFeed :: struct {
	episodes: int,
}

tuckˑfnˑparse :: proc(p0: $T0) -> tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed) {
	fmt.println("TUCK PENDING: parse invoked (not implemented)")
	return {}
}


TuckFˑtuckˑtaskˑfetchFeed :: struct {
	tuckHdr: rt.TuckFrameHdr,
	tuckRes: ^rt.TuckSlot(rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed))),
	tuckDest: ^rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed)),
	url: string,
	tuckˑvˑresp: rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_body(string)),
	tuckDefer0: bool,
}

TuckNewˑtuckˑtaskˑfetchFeed :: proc(tuckRes: ^rt.TuckSlot(rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed))), tuckDest: ^rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed)), url: string) -> ^TuckFˑtuckˑtaskˑfetchFeed {
	f := new(TuckFˑtuckˑtaskˑfetchFeed)
	f.tuckHdr.stage = TuckSˑtuckˑtaskˑfetchFeedˑ0
	f.tuckRes = tuckRes
	f.tuckDest = tuckDest
	f.url = url
	return f
}

TuckRetˑtuckˑtaskˑfetchFeed :: proc(tuckF: ^TuckFˑtuckˑtaskˑfetchFeed, v: rt.TuckResult(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed))) -> rt.TuckHop {
	rt.tuckSlFinish(tuckF.tuckRes, tuckF.tuckDest, v)
	TuckExitˑtuckˑtaskˑfetchFeed(tuckF)
	h := rt.tuckSlReturnHop(&tuckF.tuckHdr)
	free(tuckF)
	return h
}

TuckSˑtuckˑtaskˑfetchFeedˑ0 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑfetchFeed)(env)
  using tuckF
  return rt.tuckSlYield(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑfetchFeedˑ1)
}

TuckSˑtuckˑtaskˑfetchFeedˑ1 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑfetchFeed)(env)
  using tuckF
  return rt.tuckSlOnStack(&tuckF.tuckHdr, TuckSˑtuckˑtaskˑfetchFeedˑ2, TuckIOˑtuckˑtaskˑfetchFeedˑ0)
}

TuckIOˑtuckˑtaskˑfetchFeedˑ0 :: proc(env: rawptr) {
  tuckF := (^TuckFˑtuckˑtaskˑfetchFeed)(env)
  using tuckF
  tuckˑvˑresp = tuckˑmodˑhttp.tuckˑfnˑget(url)
}

TuckSˑtuckˑtaskˑfetchFeedˑ2 :: proc(env: rawptr) -> rt.TuckHop {
  tuckF := (^TuckFˑtuckˑtaskˑfetchFeed)(env)
  using tuckF
  tuckDefer0 = true
  if (tuckˑvˑresp.status == .Ok) {
      return TuckRetˑtuckˑtaskˑfetchFeed(tuckF, rt.tok(tuckˑfnˑparse(tuckˑvˑresp.value.body)))
  }
  return TuckRetˑtuckˑtaskˑfetchFeed(tuckF, rt.terr(tuckˑmodˑshapes_14_task.TRec_feed(tuckˑtypeˑFeed), u16(tuckˑvˑresp.err)))
}

TuckExitˑtuckˑtaskˑfetchFeed :: proc(tuckF: ^TuckFˑtuckˑtaskˑfetchFeed) {
  using tuckF
  if tuckDefer0 {
    rt.tuckDrop(tuckˑvˑresp)
    tuckDefer0 = false
  }
}
TuckXˑtuckˑtaskˑfetchFeedˑ0 :: proc(tuckF: ^TuckFˑtuckˑtaskˑfetchFeed) {
  using tuckF
  if tuckDefer0 {
    rt.tuckDrop(tuckˑvˑresp)
    tuckDefer0 = false
  }
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	rt.tuckAsyncInit()
	rt.tuckSlRunAll()
	rt.tuckRun()
	rt.tuckTrackCheck()
}
