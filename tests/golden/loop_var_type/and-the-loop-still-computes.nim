{.experimental: "codeReordering".}

type tuck_P* = object
  n*: int

proc tuck_total*(xs: seq[tuck_P]): int =
  var tuck_s = 0
  for tuck_x in xs:
    if true:
      tuck_s = (tuck_s + tuck_x.n)
  return tuck_s

proc tuck_main*(): int =
  return tuck_total(@[tuck_P(n: 3), tuck_P(n: 39)])

