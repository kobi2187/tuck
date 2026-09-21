#+feature dynamic-literals
package main

import sys "./mod_sys"

tuck_double :: proc (value: int) -> int {
  return (value * 2)
}

tuck_addTen :: proc (value: int) -> int {
  return (value + 10)
}

tuck_main :: proc () {
  tuck_a := tuck_double(5)
  tuck_b := tuck_addTen(tuck_double(10))
  tuck_total := (tuck_a + tuck_b)
  sys.exit(tuck_total)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
