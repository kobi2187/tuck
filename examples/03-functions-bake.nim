{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_plus*(a: int, b: int): int
proc tuck_fn_applyOperation*(a: int, b: int, op: tuck_type_BinOp): int
proc tuck_fn_main*(): void

type tuck_type_BinOp* = proc(a: int, b: int): int {.closure.}

type tuck_type_Ctx* = object
  a*: int
  b*: int
  op*: tuck_type_BinOp

proc tuck_fn_plus*(a: int, b: int): int =
  return (a + b)

proc tuck_fn_applyOperation*(a: int, b: int, op: tuck_type_BinOp): int =
  return op(a, b)

proc tuck_fn_main*(): void =
  var tuck_x = tuck_type_Ctx(a: 5, b: 10)
  var tuck_withOp = (a: tuck_x.a, b: tuck_x.b, op: tuck_fn_plus)
  var tuck_smaller = (a: tuck_withOp.a, b: 2, op: tuck_withOp.op)
  var tuck_r = tuck_fn_applyOperation(tuck_smaller.a, tuck_smaller.b, tuck_smaller.op)
  return

