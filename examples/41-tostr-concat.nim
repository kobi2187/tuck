{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import str as tuckˑmodˑstr
import console as tuckˑmodˑconsole
import sys as tuckˑmodˑsys

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑJar* = object
  count*: int
  label*: string

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑn = 99
  var tuckOwnTmp1 = tuck_rt.toStr(tuckˑvˑn)
  defer: tuckDrop(tuckOwnTmp1)
  var tuckˑvˑs = tuckConcat(tuckOwnTmp1, " bottles")
  defer: tuckDrop(tuckˑvˑs)
  tuck_rt.printLine(tuckˑvˑs)
  var tuckOwnTmp2 = tuck_rt.toStr(tuckˑvˑn)
  defer: tuckDrop(tuckOwnTmp2)
  var tuckˑvˑt = tuckConcat(tuckOwnTmp2, " more")
  defer: tuckDrop(tuckˑvˑt)
  tuck_rt.printLine(tuckˑvˑt)
  var tuckˑvˑj = tuckˑtypeˑJar(count: 7, label: tuckCopy("jam"))
  defer: tuckDrop(tuckˑvˑj.label)
  var tuckˑvˑc = tuckˑvˑj.count
  var tuckOwnTmp3 = tuckConcat(tuckˑvˑj.label, ": ")
  defer: tuckDrop(tuckOwnTmp3)
  var tuckOwnTmp4 = tuck_rt.toStr(tuckˑvˑc)
  defer: tuckDrop(tuckOwnTmp4)
  var tuckˑvˑu = tuckConcat(tuckOwnTmp3, tuckOwnTmp4)
  defer: tuckDrop(tuckˑvˑu)
  tuck_rt.printLine(tuckˑvˑu)
  if (tuckˑvˑs == "99 bottles"):
    if true:
      if (tuckˑvˑu == "jam: 7"):
        if true:
          tuck_rt.exit(0)
  tuck_rt.exit(1)

