#+feature dynamic-literals
package main

import tuckˑmodˑshapes_32_duration_units "./mod_shapes_32_duration_units"
import tuckˑmodˑsys "./mod_sys"
import tuckˑmodˑtime "./mod_time"

tuckˑfnˑasInt :: proc (d: tuckˑmodˑtime.tuckˑtypeˑMilliseconds) -> int {
  return 42
}

tuckˑfnˑbudget :: proc (d: tuckˑmodˑtime.tuckˑtypeˑMilliseconds) -> tuckˑmodˑshapes_32_duration_units.TRec_ok(bool) {
  return tuckˑmodˑshapes_32_duration_units.TRec_ok(bool){ok = true}
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑr := tuckˑfnˑbudget(tuckˑmodˑtime.tuckˑfnˑms(u32(5)))
  tuckˑvˑn := tuckˑfnˑasInt(tuckˑmodˑtime.tuckˑfnˑms(u32(42)))
  tuckˑmodˑsys.exit(tuckˑvˑn)
}

main :: proc() {
	tuckˑfnˑmain()
}
