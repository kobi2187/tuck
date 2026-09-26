{.experimental: "codeReordering".}

proc tuck_fn_use*(m: tuck_type_M): int
proc tuck_fn_main*(): int

type tuck_type_A* = object
  x*: int

type tuck_type_B* = object
  y*: int

type tuck_type_M* = object
  x*: int
  y*: int

proc tuck_fn_use*(m: tuck_type_M): int =
  return (m.x + m.y)

proc tuck_fn_main*(): int =
  return 0

