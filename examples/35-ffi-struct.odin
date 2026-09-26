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

tuckˑfnˑmain :: proc () {
  tuckˑvˑp := makesPoint(i32(3), i32(7))
  tuckˑvˑr := takesPoint(tuckˑvˑp)
  if (tuckˑvˑr == 307) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
