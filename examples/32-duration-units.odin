#+feature dynamic-literals
package main

import tuckˑmodˑsys "./mod_sys"
import tuckˑmodˑtime "./mod_time"

TRec_ok :: struct ($T_ok: typeid) {
	ok: T_ok,
}

tuckˑfnˑasInt :: proc (d: tuckˑmodˑtime.tuckˑtypeˑMilliseconds) -> int {
  return 42
}

tuckˑfnˑbudget :: proc (d: tuckˑmodˑtime.tuckˑtypeˑMilliseconds) -> TRec_ok(bool) {
  return TRec_ok(bool){ok = true}
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑr := tuckˑfnˑbudget(tuckˑmodˑtime.tuckˑfnˑms(u32(5)))
  tuckˑvˑn := tuckˑfnˑasInt(tuckˑmodˑtime.tuckˑfnˑms(u32(42)))
  tuckˑmodˑsys.exit(tuckˑvˑn)
}

main :: proc() {
	tuckˑfnˑmain()
}
