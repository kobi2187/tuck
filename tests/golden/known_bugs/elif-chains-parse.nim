{.experimental: "codeReordering".}

proc tuck_fn_classify*(n: int): int
proc tuck_fn_main*(): int

proc tuck_fn_classify*(n: int): int =
  if (n < 0):
    if true:
      return 0
  else:
    if (n == 0):
      if true:
        return 1
    else:
      if (n < 10):
        if true:
          return 2
      else:
        if true:
          return 3

proc tuck_fn_main*(): int =
  return tuck_fn_classify(5)

