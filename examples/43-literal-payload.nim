{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuckˑfnˑdouble*(value: int): int
proc tuckˑfnˑaddTen*(value: int): int
proc tuckˑfnˑmain*(): void

proc tuckˑfnˑdouble*(value: int): int =
  return (value * 2)

proc tuckˑfnˑaddTen*(value: int): int =
  return (value + 10)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑa = tuckˑfnˑdouble(5)
  var tuckˑvˑb = tuckˑfnˑaddTen(tuckˑfnˑdouble(10))
  var tuckˑvˑtotal = (tuckˑvˑa + tuckˑvˑb)
  sys.exit(tuckˑvˑtotal)

