{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuckˑfnˑplus*(a: int, b: int): int
proc tuckˑfnˑmain*(): void

type tuckˑfnsigˑAdder* = proc(a: int, b: int): int {.closure.}

type tuckˑtypeˑCalc* = object
  add*: tuckˑfnsigˑAdder

proc tuckˑfnˑplus*(a: int, b: int): int =
  return (a + b)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑc = tuckˑtypeˑCalc(add: tuckˑfnˑplus)
  var tuckˑvˑr = tuckˑvˑc.add(40, 2)
  sys.exit(tuckˑvˑr)

