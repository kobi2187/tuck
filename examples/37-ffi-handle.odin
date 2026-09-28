#+feature dynamic-literals
package main

import sys "./mod_sys"
foreign import point "cffi/point.o"

Counter :: rawptr

@(default_calling_convention="c")
foreign point {
	counterNew :: proc(start: i32) -> Counter ---
	counterBump :: proc(c: Counter, by: i32) -> i32 ---
	counterFree :: proc(c: Counter) ---
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑh := counterNew(i32(100))
  tuckˑvˑt := counterBump(tuckˑvˑh, i32(5))
  counterFree(tuckˑvˑh)
  if (tuckˑvˑt == 105) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	tuckˑfnˑmain()
}
