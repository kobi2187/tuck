{.experimental: "codeReordering".}

proc tuckˑfnˑclassify*(n: int): int
proc tuckˑfnˑmain*(): int

proc tuckˑfnˑclassify*(n: int): int =
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

proc tuckˑfnˑmain*(): int =
  return tuckˑfnˑclassify(5)

