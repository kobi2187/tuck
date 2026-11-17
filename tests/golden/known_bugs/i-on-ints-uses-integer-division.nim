{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = 10
  tuckˑvˑa = tuckDivI[int](tuckˑvˑa, 4)
  return tuckˑvˑa

