{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuckˑfnˑmain*(): void

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑq = (7 div 2)
  var tuckˑvˑr = (7.0 / 2.0)
  var tuckˑvˑbudget = 100
  tuckˑvˑbudget = (tuckˑvˑbudget div 8)
  if (tuckˑvˑq == 3):
    if true:
      if (tuckˑvˑbudget == 12):
        if true:
          if (tuckˑvˑr > 3.4):
            if true:
              tuck_rt.exit(0)
  tuck_rt.exit(1)

