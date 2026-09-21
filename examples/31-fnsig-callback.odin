#+feature dynamic-literals
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
  tuck_c := tuck_Calc{add = tuck_plus}
  tuck_r := tuck_c.add(40, 2)
  sys.exit(tuck_r)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
