{.experimental: "codeReordering".}
import ../../compiler/tuck_rt

type tuck_Pt* = object
  x*: int
  y*: int

proc tuck_main*(): int =
  var tuck_merge = 3
  var tuck_a = tuck_Pt(x: 1, y: 2)
  var tuck_b = tuck_Pt(x: tuck_merge, y: tuck_a.y)
  return (tuck_b.x - 3)

