{.experimental: "codeReordering".}

proc tuck_main*(): int =
  var a = 10
  a = (a div 4)
  return a

