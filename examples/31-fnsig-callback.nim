{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

type tuck_Adder* = proc(a: int, b: int): int {.closure.}

type tuck_Calc* = object
  add*: tuck_Adder

proc tuck_plus*(a: int, b: int): int =
  return (a + b)

proc tuck_main*(): void =
  var c = tuck_Calc(add: tuck_plus)
  var r = c.add(40, 2)
  sys.exit(r)

