{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

type tuck_Color* = enum Red, Green, Blue

proc tuck_main*(): void =
  var tuck_hot = true
  var tuck_limit = (if tuck_hot: 90 else: 20)
  var tuck_c = tuck_Color.Green
  var tuck_code = (case tuck_c
  of Red:
    1
  of Green:
    2
  of Blue:
    3)
  var tuck_name = (case tuck_c
  of Red:
    10
  of Green:
    20
  of Blue:
    30)
  var tuck_scaled = (case tuck_c
  of Red:
    (if tuck_hot: 100 else: 1)
  of Green:
    (if tuck_hot: 200 else: 2)
  of Blue:
    (if tuck_hot: 300 else: 3))
  if (tuck_limit == 90):
    if true:
      if (tuck_code == 2):
        if true:
          if (tuck_name == 20):
            if true:
              if (tuck_scaled == 200):
                if true:
                  tuck_rt.exit(0)
  tuck_rt.exit(1)

