{.experimental: "codeReordering".}

proc tuck_main*(): int

type tuck_A* = object
  x*: int

type tuck_Obj* = object
  x*: int

proc tuck_Obj_get*(self: var tuck_Obj): int =
  return self.x


proc tuck_main*(): int =
  return 0

