{.experimental: "codeReordering".}

proc tuck_fn_main*(): int

type tuck_type_A* = object
  x*: int

type tuck_type_B* = object
  y*: int

type tuck_type_Obj* = object
  x*: int
  y*: int

proc tuck_type_Obj_total*(self: var tuck_type_Obj): int =
  return (self.x + self.y)


proc tuck_fn_main*(): int =
  return 0

