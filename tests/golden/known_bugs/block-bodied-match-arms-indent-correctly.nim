{.experimental: "codeReordering".}

proc tuck_fn_describe*(l: tuck_type_Light): int
proc tuck_fn_main*(): int

type tuck_type_Light* = enum Red, Green

proc tuck_fn_describe*(l: tuck_type_Light): int =
  (case l
  of Red:
    if true:
      var tuck_a = 1
      return tuck_a
  of Green:
    if true:
      var tuck_b = 2
      return tuck_b)

proc tuck_fn_main*(): int =
  return tuck_fn_describe(tuck_type_Light.Green)

