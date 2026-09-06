{.experimental: "codeReordering".}
import ../../compiler/tuck_rt

type tuck_P* = object
  a*: int
  b*: int

proc tuck_main*(): int =
  var tuck_x = tuck_P(a: 5)
  var tuck_y = (a: tuck_x.a, b: 2)
  return (tuck_y.b - 2)


when isMainModule:
  quit(tuck_main())
