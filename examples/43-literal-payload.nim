{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuck_fn_double*(value: int): int
proc tuck_fn_addTen*(value: int): int
proc tuck_fn_main*(): void

proc tuck_fn_double*(value: int): int =
  return (value * 2)

proc tuck_fn_addTen*(value: int): int =
  return (value + 10)

proc tuck_fn_main*(): void =
  var tuck_a = tuck_fn_double(5)
  var tuck_b = tuck_fn_addTen(tuck_fn_double(10))
  var tuck_total = (tuck_a + tuck_b)
  sys.exit(tuck_total)

