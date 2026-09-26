{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

type tuckˑtypeˑA* = object
  x*: int

type tuckˑobjectˑObj* = object
  own*: int
  x*: int

proc tuckˑobjectˑObj_total*(self: var tuckˑobjectˑObj): int =
  return (self.own + self.x)


proc tuckˑfnˑmain*(): int =
  return 0

