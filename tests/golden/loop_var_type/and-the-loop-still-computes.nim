{.experimental: "codeReordering".}

proc tuck_fn_total*(xs: sink seq[tuck_type_P]): int
proc tuck_fn_main*(): int

type tuck_type_P* = object
  n*: int

proc tuck_fn_total*(xs: sink seq[tuck_type_P]): int =
  var tuck_s = 0
  for tuck_x in xs:
    if true:
      tuck_s = (tuck_s + tuck_x.n)
  return tuck_s

proc tuck_fn_main*(): int =
  return tuck_fn_total(@[tuck_type_P(n: 3), tuck_type_P(n: 39)])

