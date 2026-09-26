{.experimental: "codeReordering".}

proc tuckˑdecisionˑroute*(priority: tuckˑtypeˑPriority, encrypted: bool): int
proc tuckˑfnˑmain*(): int

type tuckˑtypeˑPriority* = enum high, low

proc tuckˑdecisionˑroute*(priority: tuckˑtypeˑPriority, encrypted: bool): int =
  (case ((ord(priority) * 2) + ord(encrypted))
  of 0, 2, 3:
    return 2
  else:
    return 1)

proc tuckˑfnˑmain*(): int =
  return tuckˑdecisionˑroute(tuckˑtypeˑPriority.low, false)

