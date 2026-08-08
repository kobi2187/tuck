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
  m := applyOp(Op.OP_MUL, 6, 7)
  c := callBack(tuck_addTwo, 40, 2)
  if (m == 42) {
      if (c == 1042) {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	tuck_main()
}
