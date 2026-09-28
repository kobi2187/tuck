{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.compile: "cffi/point.c".}
import sys

proc tuckˑfnˑaddTwo*(a: int32, b: int32): int32
proc tuckˑfnˑmain*(): void

type tuckˑfnsigˑBinOp* = proc(a: int32, b: int32): int32 {.cdecl.}

type Op* = enum OP_ADD = 10, OP_MUL = 20, OP_NEG = 30

proc applyOp*(op: Op, a: int32, b: int32): int32 {.importc: "applyOp", header: "point.h".}
proc callBack*(cb: tuckˑfnsigˑBinOp, a: int32, b: int32): int32 {.importc: "callBack", header: "point.h".}

proc tuckˑfnˑaddTwo*(a: int32, b: int32): int32 =
  return (a + b)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑm = applyOp(Op.OP_MUL, 6'i32, 7'i32)
  var tuckˑvˑc = callBack(cast[tuckˑfnsigˑBinOp](tuckˑfnˑaddTwo), 40'i32, 2'i32)
  if (tuckˑvˑm == 42):
    if true:
      if (tuckˑvˑc == 1042):
        if true:
          tuck_rt.exit(0)
  tuck_rt.exit(1)

