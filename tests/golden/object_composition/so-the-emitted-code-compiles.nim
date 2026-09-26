{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

type tuckˑtypeˑA* = object
  x*: int

type tuckˑobjectˑObj* = object
  x*: int

proc tuckˑobjectˑObj_get*(self: var tuckˑobjectˑObj): int =
  return self.x


proc tuckˑfnˑmain*(): int =
  return 0

