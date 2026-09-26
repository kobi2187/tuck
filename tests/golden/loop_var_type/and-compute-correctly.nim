{.experimental: "codeReordering".}

proc tuckˑfnˑboth*(ps: sink seq[tuckˑtypeˑP], qs: seq[tuckˑtypeˑQ]): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑP* = object
  n*: int

type tuckˑtypeˑQ* = object
  m*: int

proc tuckˑfnˑboth*(ps: sink seq[tuckˑtypeˑP], qs: seq[tuckˑtypeˑQ]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑp in ps:
    if true:
      for tuckˑvˑq in qs:
        if true:
          tuckˑvˑs = ((tuckˑvˑs + tuckˑvˑp.n) + tuckˑvˑq.m)
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  return tuckˑfnˑboth(@[tuckˑtypeˑP(n: 1)], @[tuckˑtypeˑQ(m: 41)])

