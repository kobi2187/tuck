import ../compiler/tuck_rt
{.compile: "cffi/point.c".}
import sys

type Point* {.importc: "Point", header: "point.h", bycopy.} = object
    x*: int32
    y*: int32

proc takesPoint*(p: Point): int32 {.importc: "takesPoint", header: "point.h".}
proc makesPoint*(x: int32, y: int32): Point {.importc: "makesPoint", header: "point.h".}

proc tuck_main*(): void =
  var p = makesPoint(3, 7)
  var r = takesPoint(p)
  if (r == 307):
    if true:
      exit(0)
  exit(1)

