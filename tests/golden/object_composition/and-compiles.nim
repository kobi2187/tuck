{.experimental: "codeReordering".}

proc tuck_setN*(self: tuck_App, n: int): tuck_App
proc tuck_main*(): int

type tuck_App* = object
  n*: int

proc tuck_setN*(self: tuck_App, n: int): tuck_App =
  return self

proc tuck_main*(): int =
  var tuck_a = tuck_App(n: 0)
  var tuckChain1 = tuck_a
  tuckChain1 = tuck_setN(tuckChain1, 5)
  tuckChain1 = tuck_setN(tuckChain1, 7)
  var tuck_b = tuckChain1
  return tuck_b.n

