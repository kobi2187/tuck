#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuckˑtypeˑEthernetFrame :: struct {
	len: int,
	bytes: [128]u8,
}

tuckˑtypeˑHeader :: struct {
	len: int,
	frame: rt.SlabRef,
}

tuckˑarenaˑScratchSpace := rt.ArenaBudget{size = 2048}
tuckˑarenaˑScratchSpace_reset :: proc() {
	rt.tuckSlabReset(&tuckˑslabˑScratchSpace_EthernetFrame)
	rt.tuckSlabReset(&tuckˑslabˑScratchSpace_Header)
	tuckˑarenaˑScratchSpace.used = 0
}

tuckˑslabˑScratchSpace_EthernetFrame := rt.SlabChunked(tuckˑtypeˑEthernetFrame){name = "ScratchSpace"}

tuckˑslabˑScratchSpace_Header := rt.SlabChunked(tuckˑtypeˑHeader){name = "ScratchSpace"}

tuckˑfnˑhandle :: proc (len: int) -> int {
  tuckˑvˑraw: [128]u8 = [128]u8{}
  tuckˑvˑf := tuckˑtypeˑEthernetFrame{len = len, bytes = tuckˑvˑraw}
  tuckˑvˑfr := rt.tuckArenaNew(&tuckˑslabˑScratchSpace_EthernetFrame, &tuckˑarenaˑScratchSpace, 144, tuckˑvˑf)
  if !(tuckˑvˑfr.status == .Ok) {
      return 0
  }
  tuckˑvˑh := tuckˑtypeˑHeader{len = len, frame = tuckˑvˑfr.value}
  tuckˑvˑhr := rt.tuckArenaNew(&tuckˑslabˑScratchSpace_Header, &tuckˑarenaˑScratchSpace, 24, tuckˑvˑh)
  if !(tuckˑvˑhr.status == .Ok) {
      return 0
  }
  rt.tuckSlabCell(&tuckˑslabˑScratchSpace_EthernetFrame, rt.tuckSlabCell(&tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len = (rt.tuckSlabCell(&tuckˑslabˑScratchSpace_EthernetFrame, rt.tuckSlabCell(&tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len + 1)
  return rt.tuckSlabCell(&tuckˑslabˑScratchSpace_EthernetFrame, rt.tuckSlabCell(&tuckˑslabˑScratchSpace_Header, tuckˑvˑhr.value).value.frame).value.len
}

tuckˑfnˑmain :: proc () -> int {
  tuckˑvˑhandled := 0
  tuckˑvˑi := 0
  for (tuckˑvˑi < 5) {
      tuckˑvˑhandled = (tuckˑvˑhandled + tuckˑfnˑhandle(10))
      tuckˑvˑi = (tuckˑvˑi + 1)
  }
  tuckˑarenaˑScratchSpace_reset()
  return tuckˑvˑhandled
}

tuckSlabsRelease :: proc() {
	when rt.TUCK_TRACK {
		rt.tuckSlabRelease(&tuckˑslabˑScratchSpace_EthernetFrame)
		rt.tuckSlabRelease(&tuckˑslabˑScratchSpace_Header)
	}
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	mainRc := tuckˑfnˑmain()
	tuckSlabsRelease()
	rt.tuckTrackCheck()
	os.exit(mainRc)
}
