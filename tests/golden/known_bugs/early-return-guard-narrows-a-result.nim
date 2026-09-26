{.experimental: "codeReordering".}

proc tuckˑfnˑreadIt*(n: int): TuckResult[tuple[v: int]]
proc tuckˑfnˑmain*(): int

proc tuckˑfnˑreadIt*(n: int): TuckResult[tuple[v: int]] =
  return tok((v: n))

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑr = tuckˑfnˑreadIt(5)
  if not tuckˑvˑr.ok:
    if true:
      return 0
  return tuckˑvˑr.value.v

