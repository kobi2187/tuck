#+feature dynamic-literals
package main

import rt "./tuckrt"

TRec_value :: struct ($T_value: typeid) {
	value: T_value,
}

tuck_unhandled :: proc(code: u16, site: string) {
	rt.tuckReportUnhandled(code, site)
}

tuckˑfnˑreadSensor :: proc (port: u8) -> rt.TuckResult(TRec_value(u16)) {
  if (port > 3) {
      return rt.terr(TRec_value(u16), 0x2DDC /* badPort */)
  }
  return rt.tok(TRec_value(u16){value = u16(42)})
}

tuckˑfnˑpoll :: proc (port: u8) -> int {
	tuckDrop1 := tuckˑfnˑreadSensor(port)
	if tuckDrop1.status != .Ok { tuck_unhandled(tuckDrop1.err, "poll line 18") }
  return 0
}

main :: proc() {
}
