{.experimental: "codeReordering".}
import str

proc tuck_main*(): int =
  var n = 3
  var s = tuckConcat(tuck_rt.toStr(n), " bottles")
  return 0

