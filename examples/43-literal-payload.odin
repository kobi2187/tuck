#+feature dynamic-literals
package main

import sys "./mod_sys"

tuck_fn_double :: proc (value: int) -> int {
  return (value * 2)
}

tuck_fn_addTen :: proc (value: int) -> int {
  return (value + 10)
}

tuck_fn_main :: proc () {
  tuck_a := tuck_fn_double(5)
  tuck_b := tuck_fn_addTen(tuck_fn_double(10))
  tuck_total := (tuck_a + tuck_b)
  sys.exit(tuck_total)
}

main :: proc() {
	tuck_fn_main()
}
