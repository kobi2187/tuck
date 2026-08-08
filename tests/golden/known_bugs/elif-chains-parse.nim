
proc tuck_classify*(n: int): int =
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

proc tuck_main*(): int =
  return tuck_classify(5)

