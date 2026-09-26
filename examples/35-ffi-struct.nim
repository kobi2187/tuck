{.experimental: "codeReordering".}
import ../compiler/tuck_rt
{.compile: "cffi/point.c".}
import sys

proc tuckˑfnˑmain*(): void

type Point* {.importc: "Point", header: "point.h", bycopy.} = object
  x*: int32
  y*: int32

proc takesPoint*(p: Point): int32 {.importc: "takesPoint", header: "point.h".}
proc makesPoint*(x: int32, y: int32): Point {.importc: "makesPoint", header: "point.h".}

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑp = makesPoint(3'i32, 7'i32)
  var tuckˑvˑr = takesPoint(tuckˑvˑp)
  if (tuckˑvˑr == 307):
    if true:
      tuck_rt.exit(0)
  tuck_rt.exit(1)

