
type tuck_A* = object
    x*: int

type tuck_Obj* = object
    own*: int
    x*: int

proc total*(self: var tuck_Obj): int =
  return (self.own + self.x)


proc tuck_main*(): int =
  return 0

