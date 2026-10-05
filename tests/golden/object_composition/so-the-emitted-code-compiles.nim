{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

type tuckˑtypeˑA* = object
  x*: int

type tuckˑobjectˑObj* = object
  x*: int

proc tuckˑobjectˑObjˑget*(self: tuckˑobjectˑObj): int =
  return self.x


proc tuckˑfnˑmain*(): int =
  return 0

