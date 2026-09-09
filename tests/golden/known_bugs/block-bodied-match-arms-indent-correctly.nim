{.experimental: "codeReordering".}

proc tuck_describe*(l: tuck_Light): int
proc tuck_main*(): int

type tuck_Light* = enum Red, Green

proc tuck_describe*(l: tuck_Light): int =
  (case l
  of Red:
    if true:
      var tuck_a = 1
      return tuck_a
  of Green:
    if true:
      var tuck_b = 2
      return tuck_b)

proc tuck_main*(): int =
  return tuck_describe(tuck_Light.Green)

