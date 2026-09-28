{.experimental: "codeReordering".}

proc tuckˑfnˑmain*(): int

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑs = 0
  for tuckˑvˑi in (0 ..< 4):
    if true:
      tuckˑvˑs = (tuckˑvˑs + tuckˑvˑi)
  return tuckˑvˑs

