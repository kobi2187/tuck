{.experimental: "codeReordering".}

type tuck_App* = object
  n*: int

proc tuck_loadEp*(self: tuck_App, n: int): tuck_App =
  return self

proc tuck_startAudio*(self: tuck_App): void =
  return

proc play*(self: var tuck_App, n: int): void =
  var tuckChain35 = self
  tuckChain35 = tuck_loadEp(tuckChain35, n)
  tuck_startAudio(tuckChain35)


proc tuck_main*(): int =
  var a = tuck_App(n: 1)
  return 0

