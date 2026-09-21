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

tuck_main :: proc () {
  tuck_h := counterNew(i32(100))
  tuck_t := counterBump(tuck_h, i32(5))
  counterFree(tuck_h)
  if (tuck_t == 105) {
      sys.exit(0)
  }
  sys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
