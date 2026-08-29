{.experimental: "codeReordering".}

proc tuck_main*(): int =
  var s = 0
  for i in (0 ..< 4):
    if true:
      s = (s + i)
  return s

