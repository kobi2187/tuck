{.experimental: "codeReordering".}

type tuck_P* = object
  n*: int

proc tuck_total*(xs: seq[tuck_P]): int =
  var s = 0
  for x in xs:
    if true:
      s = (s + x.n)
  return s

proc tuck_main*(): int =
  return tuck_total(@[tuck_P(n: 3), tuck_P(n: 39)])

