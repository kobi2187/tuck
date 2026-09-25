{.experimental: "codeReordering".}

proc tuck_fn_main*(): int

proc tuck_fn_main*(): int =
  var tuck_s = 0
  for tuck_i in (0 ..< 4):
    if true:
      tuck_s = (tuck_s + tuck_i)
  return tuck_s

