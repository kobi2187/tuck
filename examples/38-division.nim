import ../compiler/tuck_rt
import sys

proc tuck_main*(): void =
  var q = (7 div 2)
  var r = (7.0 / 2.0)
  var budget = 100
  budget = (budget div 8)
  if (q == 3):
    if true:
      if (budget == 12):
        if true:
          if (r > 3.4):
            if true:
              exit(0)
  exit(1)

