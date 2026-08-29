{.experimental: "codeReordering".}

proc tuck_readIt*(n: int): TuckResult[tuple[v: int]] =
  return tok((v: n))

proc tuck_main*(): int =
  var r = tuck_readIt(5)
  if not r.ok:
    if true:
      return 0
  return r.value.v

