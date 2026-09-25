{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuck_fn_plus*(a: int, b: int): int
proc tuck_fn_main*(): void

type tuck_type_Adder* = proc(a: int, b: int): int {.closure.}

type tuck_type_Calc* = object
  add*: tuck_type_Adder

proc tuck_fn_plus*(a: int, b: int): int =
  return (a + b)

proc tuck_fn_main*(): void =
  var tuck_c = tuck_type_Calc(add: tuck_fn_plus)
  var tuck_r = tuck_c.add(40, 2)
  sys.exit(tuck_r)

