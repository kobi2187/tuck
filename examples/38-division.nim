{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuck_main*(): void =
  var tuck_q = (7 div 2)
  var tuck_r = (7.0 / 2.0)
  var tuck_budget = 100
  tuck_budget = (tuck_budget div 8)
  if (tuck_q == 3):
    if true:
      if (tuck_budget == 12):
        if true:
          if (tuck_r > 3.4):
            if true:
              tuck_rt.exit(0)
  tuck_rt.exit(1)

