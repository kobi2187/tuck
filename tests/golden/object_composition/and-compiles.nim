{.experimental: "codeReordering".}

proc tuckˑfnˑsetN*(self: tuckˑobjectˑApp, n: int): tuckˑobjectˑApp
proc tuckˑfnˑmain*(): int

type tuckˑobjectˑApp* = object
  n*: int

proc tuckˑfnˑsetN*(self: tuckˑobjectˑApp, n: int): tuckˑobjectˑApp =
  return self

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = tuckˑobjectˑApp(n: 0)
  var tuckChain1 = tuckˑvˑa
  tuckChain1 = tuckˑfnˑsetN(tuckChain1, 5)
  tuckChain1 = tuckˑfnˑsetN(tuckChain1, 7)
  var tuckˑvˑb = tuckChain1
  return tuckˑvˑb.n

