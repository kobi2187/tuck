package main

import sys "./mod_sys"

tuck_Adder :: proc (a: int, b: int) -> int

tuck_Calc :: struct {
	add: tuck_Adder,
}

tuck_plus :: proc (a: int, b: int) -> int {
  return (a + b)
}

tuck_main :: proc () {
  c := tuck_Calc{add = tuck_plus}
  r := c.add(40, 2)
  sys.exit(r)
}

main :: proc() {
	tuck_main()
}
