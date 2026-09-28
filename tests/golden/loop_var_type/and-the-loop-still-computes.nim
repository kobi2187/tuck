{.experimental: "codeReordering".}

proc tuckˑfnˑtotal*(xs: sink seq[tuckˑtypeˑP]): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑP* = object
  n*: int

proc tuckˑfnˑtotal*(xs: sink seq[tuckˑtypeˑP]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑx in xs:
    if true:
      tuckˑvˑs = (tuckˑvˑs + tuckˑvˑx.n)
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  return tuckˑfnˑtotal(@[tuckˑtypeˑP(n: 3), tuckˑtypeˑP(n: 39)])

