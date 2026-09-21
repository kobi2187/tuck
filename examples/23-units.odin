#+feature dynamic-literals
package main

TRec_done :: struct ($T_done: typeid) {
	done: T_done,
}

tuck_Milliseconds :: distinct u32

tuck_ms :: proc (value: u32) -> tuck_Milliseconds {
  return tuck_Milliseconds(value)
}

tuck_delay :: proc (ms: tuck_Milliseconds) -> TRec_done(bool) {
  return TRec_done(bool){done = true}
}

tuck_main :: proc () {
  tuck_r := tuck_delay(tuck_ms(u32(5)))
  return
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
