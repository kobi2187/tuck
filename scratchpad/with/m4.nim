{.experimental: "codeReordering".}
import ../../compiler/tuck_rt

type tuck_BinOp* = proc(a: int, b: int): int {.closure.}

type tuck_Ctx* = object
  a*: int
  b*: int
  op*: tuck_BinOp

proc tuck_plus*(a: int, b: int): int =
  return (a + b)

proc tuck_applyOperation*(a: int, b: int, op: tuck_BinOp): int =
  return op(a, b)

proc tuck_main*(): int =
  var tuck_x = tuck_Ctx(a: 5, b: 10)
  var tuck_withOp = (a: tuck_x.a, b: tuck_x.b, op: tuck_plus)
  var tuck_smaller = (a: tuck_withOp.a, b: 2, op: tuck_withOp.op)
  return tuck_applyOperation(tuck_smaller.a, tuck_smaller.b, tuck_smaller.op)


when isMainModule:
  quit(tuck_main())
