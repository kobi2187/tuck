{.experimental: "codeReordering".}

proc tuck_fn_main*(): int

type tuck_type_A* = object
  x*: int

type tuck_type_Obj* = object
  x*: int

proc tuck_type_Obj_get*(self: var tuck_type_Obj): int =
  return self.x


proc tuck_fn_main*(): int =
  return 0

