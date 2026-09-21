#+feature dynamic-literals
package main

import sys "./mod_sys"
foreign import point "cffi/point.o"

tuck_BinOp :: proc "c" (a: i32, b: i32) -> i32

Op :: enum { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 }

@(default_calling_convention="c")
foreign point {
	applyOp :: proc(op: Op, a: i32, b: i32) -> i32 ---
	callBack :: proc(cb: tuck_BinOp, a: i32, b: i32) -> i32 ---
}

tuck_addTwo :: proc "c" (a: i32, b: i32) -> i32 {
  return (a + b)
}

tuck_main :: proc () {
  tuck_m := applyOp(Op.OP_MUL, i32(6), i32(7))
  tuck_c := callBack(tuck_addTwo, i32(40), i32(2))
  if (tuck_m == 42) {
      if (tuck_c == 1042) {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuck_main()
	if rt.tuckTrackReport() > 0 { os.exit(90) }
}
