{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import sys as tuckˑmodˑsys

proc tuckˑfnˑplus*(a: int, b: int): int
proc tuckˑfnˑmain*(): void

type tuckˑfnsigˑAdder* = proc(a: int, b: int): int {.closure.}

type tuckˑtypeˑCalc* = object
  add*: tuckˑfnsigˑAdder

proc tuckˑfnˑplus*(a: int, b: int): int =
  return (a + b)

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑc = tuckˑtypeˑCalc(add: tuckˑfnˑplus)
  defer: tuckDrop(tuckˑvˑc.add)
  var tuckˑvˑr = tuckˑvˑc.add(40, 2)
  tuckˑmodˑsys.exit(tuckˑvˑr)

