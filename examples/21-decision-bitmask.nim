{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuckˑdecisionˑroute*(urgency: tuckˑtypeˑPriority, encrypted: bool): int

type tuckˑtypeˑPriority* = enum High, Low

proc tuckˑdecisionˑroute*(urgency: tuckˑtypeˑPriority, encrypted: bool): int =
  (case ((ord(urgency) * 2) + ord(encrypted))
  of 0:
    return 2
  of 1:
    return 1
  else:
    return 3)

