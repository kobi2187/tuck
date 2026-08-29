{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_BinOp* = proc(a: int, b: int): int {.closure.}

proc tuck_plus*(a: int, b: int): int =
  return (a + b)

proc tuck_applyOperation*(a: int, b: int, op: tuck_BinOp): int =
  return op(a, b)

proc tuck_main*(): void =
  var x = (a: 5, b: 10)
  var withOp = (a: x.a, b: x.b, op: tuck_plus)
  var smaller = (a: withOp.a, b: 2, op: withOp.op)
  var r = tuck_applyOperation(smaller.a, smaller.b, smaller.op)
  return

