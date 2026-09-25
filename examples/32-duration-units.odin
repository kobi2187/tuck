#+feature dynamic-literals
package main

import sys "./mod_sys"
import time "./mod_time"

TRec_ok :: struct ($T_ok: typeid) {
	ok: T_ok,
}

tuck_fn_asInt :: proc (d: time.tuck_type_Milliseconds) -> int {
  return 42
}

tuck_fn_budget :: proc (d: time.tuck_type_Milliseconds) -> TRec_ok(bool) {
  return TRec_ok(bool){ok = true}
}

tuck_fn_main :: proc () {
  tuck_r := tuck_fn_budget(time.tuck_fn_ms(u32(5)))
  tuck_n := tuck_fn_asInt(time.tuck_fn_ms(u32(42)))
  sys.exit(tuck_n)
}

main :: proc() {
	tuck_fn_main()
}
