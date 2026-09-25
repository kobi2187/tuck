#+feature dynamic-literals
package main

TRec_done :: struct ($T_done: typeid) {
	done: T_done,
}

tuck_type_Milliseconds :: distinct u32

tuck_fn_ms :: proc (value: u32) -> tuck_type_Milliseconds {
  return tuck_type_Milliseconds(value)
}

tuck_fn_delay :: proc (ms: tuck_type_Milliseconds) -> TRec_done(bool) {
  return TRec_done(bool){done = true}
}

tuck_fn_main :: proc () {
  tuck_r := tuck_fn_delay(tuck_fn_ms(u32(5)))
  return
}

main :: proc() {
	tuck_fn_main()
}
