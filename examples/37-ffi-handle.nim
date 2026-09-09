{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.compile: "cffi/point.c".}
import sys

proc tuck_main*(): void

type CounterObj {.importc: "Counter", header: "point.h", incompleteStruct.} = object
type Counter* = ptr CounterObj

proc counterNew*(start: int32): Counter {.importc: "counterNew", header: "point.h".}
proc counterBump*(c: Counter, by: int32): int32 {.importc: "counterBump", header: "point.h".}
proc counterFree*(c: Counter): void {.importc: "counterFree", header: "point.h".}

proc tuck_main*(): void =
  var tuck_h = counterNew(100'i32)
  var tuck_t = counterBump(tuck_h, 5'i32)
  counterFree(tuck_h)
  if (tuck_t == 105):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

