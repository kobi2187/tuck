{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import str
import console
import sys

type tuck_Jar* = object
  count*: int
  label*: string

proc tuck_main*(): void =
  var n = 99
  var s = tuckConcat(tuck_rt.toStr(n), " bottles")
  tuck_rt.printLine(s)
  var t = tuckConcat(tuck_rt.toStr(n), " more")
  tuck_rt.printLine(t)
  var j = tuck_Jar(count: 7, label: "jam")
  var c = j.count
  var u = tuckConcat(tuckConcat(j.label, ": "), tuck_rt.toStr(c))
  tuck_rt.printLine(u)
  if (s == "99 bottles"):
    if true:
      if (u == "jam: 7"):
        if true:
          tuck_rt.exit(0)
  tuck_rt.exit(1)

