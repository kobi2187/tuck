{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuck_double*(value: int): int =
  return (value * 2)

proc tuck_addTen*(value: int): int =
  return (value + 10)

proc tuck_main*(): void =
  var a = tuck_double(5)
  var b = tuck_addTen(tuck_double(10))
  var total = (a + b)
  sys.exit(total)

