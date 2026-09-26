{.experimental: "codeReordering".}

proc tuckˑfnˑdescribe*(l: tuckˑtypeˑLight): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑLight* = enum Red, Green

proc tuckˑfnˑdescribe*(l: tuckˑtypeˑLight): int =
  (case l
  of Red:
    if true:
      var tuckˑvˑa = 1
      return tuckˑvˑa
  of Green:
    if true:
      var tuckˑvˑb = 2
      return tuckˑvˑb)

proc tuckˑfnˑmain*(): int =
  return tuckˑfnˑdescribe(tuckˑtypeˑLight.Green)

