{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import str
import console
import sys

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑJar* = object
  count*: int
  label*: string

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑn = 99
  var tuckˑvˑs = tuckConcat(tuck_rt.toStr(tuckˑvˑn), " bottles")
  tuck_rt.printLine(tuckˑvˑs)
  var tuckˑvˑt = tuckConcat(tuck_rt.toStr(tuckˑvˑn), " more")
  tuck_rt.printLine(tuckˑvˑt)
  var tuckˑvˑj = tuckˑtypeˑJar(count: 7, label: "jam")
  var tuckˑvˑc = tuckˑvˑj.count
  var tuckˑvˑu = tuckConcat(tuckConcat(tuckˑvˑj.label, ": "), tuck_rt.toStr(tuckˑvˑc))
  tuck_rt.printLine(tuckˑvˑu)
  if (tuckˑvˑs == "99 bottles"):
    if true:
      if (tuckˑvˑu == "jam: 7"):
        if true:
          tuck_rt.exit(0)
  tuck_rt.exit(1)

