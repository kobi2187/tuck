#+feature dynamic-literals
package main

import rt "./tuckrt"
import sys "./mod_sys"
foreign import point "cffi/point.o"

tuckˑfnsigˑBinOp :: proc "c" (a: i32, b: i32) -> i32

Op :: enum { OP_ADD = 10, OP_MUL = 20, OP_NEG = 30 }

@(default_calling_convention="c")
foreign point {
	applyOp :: proc(op: Op, a: i32, b: i32) -> i32 ---
	callBack :: proc(cb: tuckˑfnsigˑBinOp, a: i32, b: i32) -> i32 ---
}

tuckˑfnˑaddTwo :: proc "c" (a: i32, b: i32) -> i32 {
  return rt.tuckArith(a, b, .Add, .Trap)
}

tuckˑfnˑmain :: proc () {
  tuckˑvˑm := applyOp(Op.OP_MUL, i32(6), i32(7))
  tuckˑvˑc := callBack(tuckˑfnˑaddTwo, i32(40), i32(2))
  if (tuckˑvˑm == i32(42)) {
      if (tuckˑvˑc == i32(1042)) {
          sys.exit(0)
      }
  }
  sys.exit(1)
}

main :: proc() {
	context.allocator = rt.tuckTrackAllocator()
	tuckˑfnˑmain()
	rt.tuckTrackCheck()
}
