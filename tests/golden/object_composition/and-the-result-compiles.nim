{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

type tuckˑtypeˑA* = object
  x*: int

type tuckˑtypeˑB* = object
  y*: int

type tuckˑobjectˑObj* = object
  x*: int
  y*: int

proc tuckˑobjectˑObj_total*(self: var tuckˑobjectˑObj): int =
  return (self.x + self.y)


proc tuckˑfnˑmain*(): int =
  return 0

