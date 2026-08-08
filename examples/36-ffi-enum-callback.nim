import ../compiler/tuck_rt
{.compile: "cffi/point.c".}
import sys

type tuck_BinOp* = proc(a: int32, b: int32): int32 {.cdecl.}

type Op* = enum OP_ADD = 10, OP_MUL = 20, OP_NEG = 30

proc applyOp*(op: Op, a: int32, b: int32): int32 {.importc: "applyOp", header: "point.h".}
proc callBack*(cb: tuck_BinOp, a: int32, b: int32): int32 {.importc: "callBack", header: "point.h".}

proc tuck_addTwo*(a: int32, b: int32): int32 =
  return (a + b)

proc tuck_main*(): void =
  var m = applyOp(Op.OP_MUL, 6, 7)
  var c = callBack(cast[tuck_BinOp](tuck_addTwo), 40, 2)
  if (m == 42):
    if true:
      if (c == 1042):
        if true:
          exit(0)
  exit(1)

