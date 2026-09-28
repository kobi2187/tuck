{.experimental: "codeReordering".}
import ../compiler/tuck_rt
import sys

proc tuckˑfnˑmain*(): void

type tuckˑtypeˑColor* = enum Red, Green, Blue

proc tuckˑfnˑmain*(): void =
  var tuckˑvˑhot = true
  var tuckˑvˑlimit = (if tuckˑvˑhot: 90 else: 20)
  var tuckˑvˑc = tuckˑtypeˑColor.Green
  var tuckˑvˑcode = (case tuckˑvˑc
  of Red:
    1
  of Green:
    2
  of Blue:
    3)
  var tuckˑvˑname = (case tuckˑvˑc
  of Red:
    10
  of Green:
    20
  of Blue:
    30)
  var tuckˑvˑscaled = (case tuckˑvˑc
  of Red:
    (if tuckˑvˑhot: 100 else: 1)
  of Green:
    (if tuckˑvˑhot: 200 else: 2)
  of Blue:
    (if tuckˑvˑhot: 300 else: 3))
  if (tuckˑvˑlimit == 90):
    if true:
      if (tuckˑvˑcode == 2):
        if true:
          if (tuckˑvˑname == 20):
            if true:
              if (tuckˑvˑscaled == 200):
                if true:
                  tuck_rt.exit(0)
  tuck_rt.exit(1)

