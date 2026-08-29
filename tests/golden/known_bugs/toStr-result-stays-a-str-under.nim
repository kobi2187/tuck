{.experimental: "codeReordering".}
import str

proc tuck_main*(): int =
  var n = 3
  var s = tuckConcat(toStr(n), " bottles")
  return 0

