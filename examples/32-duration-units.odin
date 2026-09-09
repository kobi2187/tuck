#+feature dynamic-literals
package main

import sys "./mod_sys"
import time "./mod_time"

TRec_ok_64D7 :: struct {
	ok: bool,
}

tuck_asInt :: proc (d: time.tuck_Milliseconds) -> int {
  return 42
}

tuck_budget :: proc (d: time.tuck_Milliseconds) -> TRec_ok_64D7 {
  return TRec_ok_64D7{ok = true}
}

tuck_main :: proc () {
  tuck_r := tuck_budget(time.tuck_ms(u32(5)))
  tuck_n := tuck_asInt(time.tuck_ms(u32(42)))
  sys.exit(tuck_n)
}

main :: proc() {
	tuck_main()
}
