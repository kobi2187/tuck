{.experimental: "codeReordering".}

proc tuckˑfnˑtotal*(xs: seq[tuckˑtypeˑP]): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑP* = object
  n*: int

proc tuckˑfnˑtotal*(xs: seq[tuckˑtypeˑP]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑx in xs:
    if true:
      tuckˑvˑs = (tuckˑvˑs + tuckˑvˑx.n)
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  var tuckOwnTmp1 = @[tuckˑtypeˑP(n: 3), tuckˑtypeˑP(n: 39)]
  return tuckˑfnˑtotal(tuckOwnTmp1)

