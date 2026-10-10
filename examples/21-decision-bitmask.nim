{.experimental: "codeReordering".}
import "../compiler/tuck_rt"

proc tuckˑdecisionˑroute*(urgency: tuckˑtypeˑPriority, encrypted: bool): int

type tuckˑtypeˑPriority* = enum High, Low

proc tuckˑdecisionˑroute*(urgency: tuckˑtypeˑPriority, encrypted: bool): int =
  (case ((ord(urgency) * 2) + ord(encrypted))
  of 0:
    if true:
      return 2
  of 1:
    if true:
      return 1
  else:
    if true:
      return 3)

