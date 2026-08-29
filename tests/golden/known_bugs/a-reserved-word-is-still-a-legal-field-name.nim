{.experimental: "codeReordering".}

type tuck_Priority* = enum high, low

proc tuck_route*(priority: tuck_Priority, encrypted: bool): int =
  case ord(priority) * 2 + ord(encrypted)   # packed decision key
  of 0, 2, 3: return 2
  else: return 1

proc tuck_main*(): int =
  return tuck_route(tuck_Priority.low, false)

