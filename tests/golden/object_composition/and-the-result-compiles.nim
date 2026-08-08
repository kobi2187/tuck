
type tuck_A* = object
  x*: int

type tuck_B* = object
  y*: int

type tuck_Obj* = object
  x*: int
  y*: int

proc total*(self: var tuck_Obj): int =
  return (self.x + self.y)


proc tuck_main*(): int =
  return 0

