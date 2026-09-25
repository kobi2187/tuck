{.experimental: "codeReordering".}
import ../compiler/tuck_rt

proc tuck_fn_route*(priority: tuck_type_Priority, encrypted: bool): int

type tuck_type_Priority* = enum High, Low

proc tuck_fn_route*(priority: tuck_type_Priority, encrypted: bool): int =
  (case ((ord(priority) * 2) + ord(encrypted))
  of 0:
    return 2
  of 1:
    return 1
  else:
    return 3)

