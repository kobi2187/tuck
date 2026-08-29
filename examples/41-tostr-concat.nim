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
  var s = tuckConcat(toStr(n), " bottles")
  printLine(s)
  var t = tuckConcat(toStr(n), " more")
  printLine(t)
  var j = tuck_Jar(count: 7, label: "jam")
  var c = j.count
  var u = tuckConcat(tuckConcat(j.label, ": "), toStr(c))
  printLine(u)
  if (s == "99 bottles"):
    if true:
      if (u == "jam: 7"):
        if true:
          exit(0)
  exit(1)

