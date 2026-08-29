{.experimental: "codeReordering".}
import ../compiler/tuck_rt

type tuck_Priority* = enum High, Low

proc tuck_route*(priority: tuck_Priority, encrypted: bool): int =
  case ord(priority) * 2 + ord(encrypted)   # packed decision key
  of 0: return 2
  of 1: return 1
  else: return 3

