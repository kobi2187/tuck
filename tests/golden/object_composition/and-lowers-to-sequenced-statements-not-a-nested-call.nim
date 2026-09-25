{.experimental: "codeReordering".}

proc tuck_fn_loadEp*(self: tuck_type_App, n: int): tuck_type_App
proc tuck_fn_startAudio*(self: tuck_type_App): void
proc tuck_fn_main*(): int

type tuck_type_App* = object
  n*: int

proc tuck_fn_loadEp*(self: tuck_type_App, n: int): tuck_type_App =
  return self

proc tuck_fn_startAudio*(self: tuck_type_App): void =
  return

proc tuck_type_App_play*(self: var tuck_type_App, n: int): void =
  var tuckChain1 = self
  tuckChain1 = tuck_fn_loadEp(tuckChain1, n)
  tuck_fn_startAudio(tuckChain1)


proc tuck_fn_main*(): int =
  var tuck_a = tuck_type_App(n: 1)
  return 0

