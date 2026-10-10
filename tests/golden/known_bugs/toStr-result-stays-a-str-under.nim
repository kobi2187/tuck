{.experimental: "codeReordering".}
import str

proc tuckˑfnˑmain*(): int

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑn = 3
  var tuckOwnTmp1 = tuck_rt.toStr(tuckˑvˑn)
  var tuckˑvˑs = tuckConcat(tuckOwnTmp1, " bottles")
  return 0

