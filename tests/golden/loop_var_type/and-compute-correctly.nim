{.experimental: "codeReordering".}

proc tuckˑfnˑboth*(ps: seq[tuckˑtypeˑP], qs: seq[tuckˑtypeˑQ]): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑP* = object
  n*: int

type tuckˑtypeˑQ* = object
  m*: int

proc tuckˑfnˑboth*(ps: seq[tuckˑtypeˑP], qs: seq[tuckˑtypeˑQ]): int =
  var tuckˑvˑs = 0
  for tuckˑvˑp in ps:
    if true:
      for tuckˑvˑq in qs:
        if true:
          tuckˑvˑs = ((tuckˑvˑs + tuckˑvˑp.n) + tuckˑvˑq.m)
  return tuckˑvˑs

proc tuckˑfnˑmain*(): int =
  var tuckOwnTmp1 = @[tuckˑtypeˑP(n: 1)]
  var tuckOwnTmp2 = @[tuckˑtypeˑQ(m: 41)]
  return tuckˑfnˑboth(tuckOwnTmp1, tuckOwnTmp2)

