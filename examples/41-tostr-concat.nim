{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import str
import console
import sys

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑJar* = object
  count*: int
  label*: string

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑn = 99
  var tuckOwnTmp1 = tuck_rt.toStr(tuckˑvˑn)
  var tuckˑvˑs = tuckConcat(tuckOwnTmp1, " bottles")
  tuck_rt.printLine(tuckˑvˑs)
  var tuckOwnTmp2 = tuck_rt.toStr(tuckˑvˑn)
  var tuckˑvˑt = tuckConcat(tuckOwnTmp2, " more")
  tuck_rt.printLine(tuckˑvˑt)
  var tuckˑvˑj = tuckˑtypeˑJar(count: 7, label: "jam")
  var tuckˑvˑc = tuckˑvˑj.count
  var tuckOwnTmp3 = tuckConcat(tuckˑvˑj.label, ": ")
  var tuckOwnTmp4 = tuck_rt.toStr(tuckˑvˑc)
  var tuckˑvˑu = tuckConcat(tuckOwnTmp3, tuckOwnTmp4)
  tuck_rt.printLine(tuckˑvˑu)
  if (tuckˑvˑs == "99 bottles"):
    if true:
      if (tuckˑvˑu == "jam: 7"):
        if true:
          tuck_rt.exit(0)
  tuck_rt.exit(1)

