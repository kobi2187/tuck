{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import str
import console
import sys

type tuck_Jar* = object
  count*: int
  label*: string

proc tuck_main*(): void =
  var tuck_n = 99
  var tuck_s = tuckConcat(tuck_rt.toStr(tuck_n), " bottles")
  tuck_rt.printLine(tuck_s)
  var tuck_t = tuckConcat(tuck_rt.toStr(tuck_n), " more")
  tuck_rt.printLine(tuck_t)
  var tuck_j = tuck_Jar(count: 7, label: "jam")
  var tuck_c = tuck_j.count
  var tuck_u = tuckConcat(tuckConcat(tuck_j.label, ": "), tuck_rt.toStr(tuck_c))
  tuck_rt.printLine(tuck_u)
  if (tuck_s == "99 bottles"):
    if true:
      if (tuck_u == "jam: 7"):
        if true:
          tuck_rt.exit(0)
  tuck_rt.exit(1)

