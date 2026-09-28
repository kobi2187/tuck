{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑfnˑplus*(a: int, b: int): int
proc tuckˑfnˑapplyOperation*(a: int, b: int, op: tuckˑfnsigˑBinOp): int
proc tuckˑfnˑmain*(): void

type tuckˑfnsigˑBinOp* = proc(a: int, b: int): int {.closure.}

type tuckˑtypeˑCtx* = object
  a*: int
  b*: int
  op*: tuckˑfnsigˑBinOp

proc tuckˑfnˑplus*(a: int, b: int): int =
  return (a + b)

proc tuckˑfnˑapplyOperation*(a: int, b: int, op: tuckˑfnsigˑBinOp): int =
  return op(a, b)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑx = tuckˑtypeˑCtx(a: 5, b: 10)
  var tuckˑvˑwithOp = (a: tuckˑvˑx.a, b: tuckˑvˑx.b, op: tuckˑfnˑplus)
  var tuckˑvˑsmaller = (a: tuckˑvˑwithOp.a, b: 2, op: tuckˑvˑwithOp.op)
  var tuckˑvˑr = tuckˑfnˑapplyOperation(tuckˑvˑsmaller.a, tuckˑvˑsmaller.b, tuckˑvˑsmaller.op)
  return

