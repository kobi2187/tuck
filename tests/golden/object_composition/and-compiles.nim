{.experimental: "codeReordering".}

type tuck_App* = object
  n*: int

proc tuck_setN*(self: tuck_App, n: int): tuck_App =
  return self

proc tuck_main*(): int =
  var a = tuck_App(n: 0)
  var tuckChain1 = a
  tuckChain1 = tuck_setN(tuckChain1, 5)
  tuckChain1 = tuck_setN(tuckChain1, 7)
  var b = tuckChain1
  return b.n

