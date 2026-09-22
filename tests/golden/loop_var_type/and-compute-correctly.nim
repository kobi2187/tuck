{.experimental: "codeReordering".}

proc tuck_both*(ps: sink seq[tuck_P], qs: seq[tuck_Q]): int
proc tuck_main*(): int

type tuck_P* = object
  n*: int

type tuck_Q* = object
  m*: int

proc tuck_both*(ps: sink seq[tuck_P], qs: seq[tuck_Q]): int =
  var tuck_s = 0
  for tuck_p in ps:
    if true:
      for tuck_q in qs:
        if true:
          tuck_s = ((tuck_s + tuck_p.n) + tuck_q.m)
  return tuck_s

proc tuck_main*(): int =
  return tuck_both(@[tuck_P(n: 1)], @[tuck_Q(m: 41)])

