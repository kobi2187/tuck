#+feature dynamic-literals
package main

import sys "./mod_sys"
foreign import point "cffi/point.o"

Point :: struct {
	x: i32,
	y: i32,
}

@(default_calling_convention="c")
foreign point {
	takesPoint :: proc(p: Point) -> i32 ---
	makesPoint :: proc(x: i32, y: i32) -> Point ---
}

tuck_main :: proc () {
  tuck_p := makesPoint(i32(3), i32(7))
  tuck_r := takesPoint(tuck_p)
  if (tuck_r == 307) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
