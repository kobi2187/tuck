#+feature dynamic-literals
package main

import sys "./mod_sys"

tuck_type_Adder :: proc (a: int, b: int) -> int

tuck_type_Calc :: struct {
	add: tuck_type_Adder,
}

tuck_fn_plus :: proc (a: int, b: int) -> int {
  return (a + b)
}

tuck_fn_main :: proc () {
  tuck_c := tuck_type_Calc{add = tuck_fn_plus}
  tuck_r := tuck_c.add(40, 2)
  sys.exit(tuck_r)
}

main :: proc() {
	tuck_fn_main()
}
