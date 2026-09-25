{.experimental: "codeReordering".}

proc tuck_fn_setN*(self: tuck_type_App, n: int): tuck_type_App
proc tuck_fn_main*(): int

type tuck_type_App* = object
  n*: int

proc tuck_fn_setN*(self: tuck_type_App, n: int): tuck_type_App =
  return self

proc tuck_fn_main*(): int =
  var tuck_a = tuck_type_App(n: 0)
  var tuckChain1 = tuck_a
  tuckChain1 = tuck_fn_setN(tuckChain1, 5)
  tuckChain1 = tuck_fn_setN(tuckChain1, 7)
  var tuck_b = tuckChain1
  return tuck_b.n

