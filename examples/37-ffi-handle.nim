import ../compiler/tuck_rt
{.compile: "cffi/point.c".}
import sys

type CounterObj {.importc: "Counter", header: "point.h", incompleteStruct.} = object
type Counter* = ptr CounterObj

proc counterNew*(start: int32): Counter {.importc: "counterNew", header: "point.h".}
proc counterBump*(c: Counter, by: int32): int32 {.importc: "counterBump", header: "point.h".}
proc counterFree*(c: Counter): void {.importc: "counterFree", header: "point.h".}

proc tuck_main*(): void =
  var h = counterNew(100)
  var t = counterBump(h, 5)
  counterFree(h)
  if (t == 105):
    if true:
      exit(0)
  exit(1)

