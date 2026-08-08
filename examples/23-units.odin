package main

TRec_done_7275 :: struct {
	done: bool,
}

tuck_Milliseconds :: distinct u32

tuck_ms :: proc (value: u32) -> tuck_Milliseconds {
  return tuck_Milliseconds(value)
}

tuck_delay :: proc (ms: tuck_Milliseconds) -> TRec_done_7275 {
  return TRec_done_7275{done = true}
}

tuck_main :: proc () {
  r := tuck_delay(tuck_ms(5))
  return
}

main :: proc() {
	tuck_main()
}
