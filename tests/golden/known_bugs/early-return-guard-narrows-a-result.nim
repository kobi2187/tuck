{.experimental: "codeReordering".}

proc tuck_fn_readIt*(n: int): TuckResult[tuple[v: int]]
proc tuck_fn_main*(): int

proc tuck_fn_readIt*(n: int): TuckResult[tuple[v: int]] =
  return tok((v: n))

proc tuck_fn_main*(): int =
  var tuck_r = tuck_fn_readIt(5)
  if not tuck_r.ok:
    if true:
      return 0
  return tuck_r.value.v

