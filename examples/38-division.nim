{.experimental: "codeReordering".}
import "../compiler/tuck_rt"
import sys as tuckˑmodˑsys

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑq = tuckDivI[int](7, 2, "int")
  var tuckˑvˑr = (7.0 / 2.0)
  var tuckˑvˑbudget = 100
  tuckˑvˑbudget = tuckDivI[int](tuckˑvˑbudget, 8, "int")
  if (tuckˑvˑq == 3):
    if true:
      if (tuckˑvˑbudget == 12):
        if true:
          if (tuckˑvˑr > 3.4):
            if true:
              tuck_rt.exit(0)
  tuck_rt.exit(1)

