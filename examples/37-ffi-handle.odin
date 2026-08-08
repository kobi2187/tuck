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

tuck_main :: proc () {
  h := counterNew(100)
  t := counterBump(h, 5)
  counterFree(h)
  if (t == 105) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
