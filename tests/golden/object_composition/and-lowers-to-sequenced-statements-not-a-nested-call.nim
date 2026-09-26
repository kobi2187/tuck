{.experimental: "codeReordering".}

proc tuckˑfnˑloadEp*(self: tuckˑobjectˑApp, n: int): tuckˑobjectˑApp
proc tuckˑfnˑstartAudio*(self: tuckˑobjectˑApp): void
proc tuckˑfnˑmain*(): int

type tuckˑobjectˑApp* = object
  n*: int

proc tuckˑfnˑloadEp*(self: tuckˑobjectˑApp, n: int): tuckˑobjectˑApp =
  return self

proc tuckˑfnˑstartAudio*(self: tuckˑobjectˑApp): void =
  return

proc tuckˑobjectˑApp_play*(self: var tuckˑobjectˑApp, n: int): void =
  var tuckChain1 = self
  tuckChain1 = tuckˑfnˑloadEp(tuckChain1, n)
  tuckˑfnˑstartAudio(tuckChain1)


proc tuckˑfnˑmain*(): int =
  var tuckˑvˑa = tuckˑobjectˑApp(n: 1)
  return 0

