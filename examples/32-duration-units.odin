#+feature dynamic-literals
package main

import sys "./mod_sys"
import time "./mod_time"

TRec_ok :: struct ($T_ok: typeid) {
	ok: T_ok,
}

tuckˑfnˑasInt :: proc (d: time.tuckˑtypeˑMilliseconds) -> int {
  return 42
}

tuckˑfnˑbudget :: proc (d: time.tuckˑtypeˑMilliseconds) -> TRec_ok(bool) {
  return TRec_ok(bool){ok = true}
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑr := tuckˑfnˑbudget(time.tuckˑfnˑms(u32(5)))
  tuckˑvˑn := tuckˑfnˑasInt(time.tuckˑfnˑms(u32(42)))
  sys.exit(tuckˑvˑn)
}

main :: proc() {
	tuckˑfnˑmain()
}
