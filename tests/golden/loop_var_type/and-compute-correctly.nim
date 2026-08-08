
type tuck_P* = object
    n*: int

type tuck_Q* = object
    m*: int

proc tuck_both*(ps: seq[tuck_P], qs: seq[tuck_Q]): int =
  var s = 0
  for p in ps:
    if true:
      for q in qs:
        if true:
          s = ((s + p.n) + q.m)
  return s

proc tuck_main*(): int =
  return tuck_both(@[tuck_P(n: 1)], @[tuck_Q(m: 41)])

