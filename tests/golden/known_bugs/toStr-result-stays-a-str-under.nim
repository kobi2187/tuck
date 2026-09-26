{.experimental: "codeReordering".}
import str

proc tuck_fn_main*(): int

proc tuck_fn_main*(): int =
  var tuck_n = 3
  var tuck_s = tuckConcat(tuck_rt.toStr(tuck_n), " bottles")
  return 0

