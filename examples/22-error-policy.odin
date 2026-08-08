package main

import rt "./tuckrt"

TRec_value_638E :: struct {
	value: u16,
}

tuck_unhandled :: proc(code: u16, site: string) {
	rt.tuckReportUnhandled(code, site)
}

tuck_readSensor :: proc (port: u8) -> rt.TuckResult(TRec_value_638E) {
  if (port > 3) {
      return rt.terr(TRec_value_638E, 0x2DDC /* badPort */)
  }
  return rt.tok(TRec_value_638E{value = u16(42)})
}

tuck_poll :: proc (port: u8) -> int {
	tuckDrop1 := tuck_readSensor(port)
	if tuckDrop1.status != .Ok { tuck_unhandled(tuckDrop1.err, "poll line 18") }
  return 0
}

main :: proc() {
}
