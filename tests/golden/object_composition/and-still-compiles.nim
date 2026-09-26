{.experimental: "codeReordering".}

proc tuckˑfnˑuse*(m: tuckˑtypeˑM): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑA* = object
  x*: int

type tuckˑtypeˑB* = object
  y*: int

type tuckˑtypeˑM* = object
  x*: int
  y*: int

proc tuckˑfnˑuse*(m: tuckˑtypeˑM): int =
  return (m.x + m.y)

proc tuckˑfnˑmain*(): int =
  return 0

