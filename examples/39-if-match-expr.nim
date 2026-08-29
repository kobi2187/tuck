{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

type tuck_Color* = enum Red, Green, Blue

proc tuck_main*(): void =
  var hot = true
  var limit = (if hot: 90 else: 20)
  var c = tuck_Color.Green
  var code = (case c
  of Red:
    1
  of Green:
    2
  of Blue:
    3)
  var name = (case c
  of Red:
    10
  of Green:
    20
  of Blue:
    30)
  var scaled = (case c
  of Red:
    (if hot: 100 else: 1)
  of Green:
    (if hot: 200 else: 2)
  of Blue:
    (if hot: 300 else: 3))
  if (limit == 90):
    if true:
      if (code == 2):
        if true:
          if (name == 20):
            if true:
              if (scaled == 200):
                if true:
                  exit(0)
  exit(1)

