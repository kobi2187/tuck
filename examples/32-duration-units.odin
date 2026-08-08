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
  r := tuck_budget(time.tuck_ms(5))
  n := tuck_asInt(time.tuck_ms(42))
  sys.exit(n)
}

main :: proc() {
	tuck_main()
}
