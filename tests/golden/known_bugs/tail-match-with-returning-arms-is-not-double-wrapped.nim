{.experimental: "codeReordering".}

type tuck_Light* = enum Red, Green

proc tuck_describe*(l: tuck_Light): int =
  (case l
  of Red:
    if true:
      var a = 1
      return a
  of Green:
    if true:
      var b = 2
      return b)

proc tuck_main*(): int =
  return tuck_describe(tuck_Light.Green)

