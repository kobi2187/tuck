
type tuck_A* = object
  x*: int

type tuck_B* = object
  y*: int

type tuck_M* = object
  x*: int
  y*: int

proc tuck_use*(m: tuck_M): int =
  return (m.x + m.y)

proc tuck_main*(): int =
  return 0

