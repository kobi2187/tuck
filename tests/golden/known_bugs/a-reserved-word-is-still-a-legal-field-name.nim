{.experimental: "codeReordering".}

proc tuck_fn_route*(priority: tuck_type_Priority, encrypted: bool): int
proc tuck_fn_main*(): int

type tuck_type_Priority* = enum high, low

proc tuck_fn_route*(priority: tuck_type_Priority, encrypted: bool): int =
  (case ((ord(priority) * 2) + ord(encrypted))
  of 0, 2, 3:
    return 2
  else:
    return 1)

proc tuck_fn_main*(): int =
  return tuck_fn_route(tuck_type_Priority.low, false)

