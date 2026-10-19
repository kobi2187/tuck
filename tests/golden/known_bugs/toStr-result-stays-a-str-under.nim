{.experimental: "codeReordering".}
import str as tuckˑmodˑstr

proc tuckˑfnˑmain*(): int

proc tuckˑfnˑmain*(): int =
  var tuckˑvˑn = 3
  var tuckOwnTmp1 = tuck_rt.toStr(tuckˑvˑn)
  defer: tuckDrop(tuckOwnTmp1)
  var tuckˑvˑs = tuckConcat(tuckOwnTmp1, " bottles")
  defer: tuckDrop(tuckˑvˑs)
  return 0

