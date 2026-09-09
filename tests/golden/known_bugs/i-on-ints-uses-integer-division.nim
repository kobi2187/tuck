{.experimental: "codeReordering".}

proc tuck_main*(): int

proc tuck_main*(): int =
  var tuck_a = 10
  tuck_a = (tuck_a div 4)
  return tuck_a

