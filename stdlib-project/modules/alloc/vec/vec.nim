{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq

proc tuck_count*[T](items: sink seq[T]): int
proc tuck_isEmpty*[T](items: sink seq[T]): bool
proc tuckfn_at*[T](items: sink seq[T], index: int): TuckResult[T]
proc tuck_first*[T](items: sink seq[T]): TuckResult[T]
proc tuck_last*[T](items: sink seq[T]): TuckResult[T]
proc tuckfn_setAt*[T](items: sink seq[T], index: int, value: T): seq[T]
proc tuck_clear*[T](items: seq[T]): seq[T]
proc tuck_has*[T](items: seq[T], value: T): bool
proc tuck_indexOf*[T](items: seq[T], value: T): TuckResult[int]
proc tuck_insertAt*[T](items: seq[T], index: int, value: T): seq[T]
proc tuck_removeAt*[T](items: seq[T], index: int): seq[T]
proc tuck_pop*[T](items: sink seq[T]): TuckResult[tuple[rest: seq[T], value: T]]
proc tuck_checkReads*(): int
proc tuck_checkEnds*(): int
proc tuck_checkSearch*(): int
proc tuck_checkEdits*(): int
proc tuck_checkPop*(): int
proc tuck_main*(): int

proc tuck_count*[T](items: sink seq[T]): int =
  return len(items)

proc tuck_isEmpty*[T](items: sink seq[T]): bool =
  return (len(items) == 0)

proc tuckfn_at*[T](items: sink seq[T], index: int): TuckResult[T] =
  if ((index < 0) or (index >= len(items))):
    if true:
      return tnone[T]()
  return tok(tuck_rt.tuckAt(items, index))

proc tuck_first*[T](items: sink seq[T]): TuckResult[T] =
  return tuckfn_at(items, 0)

proc tuck_last*[T](items: sink seq[T]): TuckResult[T] =
  return tuckfn_at(items, (len(items) - 1))

proc tuckfn_setAt*[T](items: sink seq[T], index: int, value: T): seq[T] =
  if ((index < 0) or (index >= len(items))):
    if true:
      return items
  var tuck_out = items
  tuck_rt.tuckSetAt(tuck_out, index, value)
  return tuck_out

proc tuck_clear*[T](items: seq[T]): seq[T] =
  var tuck_empty: seq[T] = @[]
  return tuck_empty

proc tuck_has*[T](items: seq[T], value: T): bool =
  for tuck_i in (0 .. (len(items) - 1)):
    if true:
      if (tuck_rt.tuckAt(items, tuck_i) == value):
        if true:
          return true
  return false

proc tuck_indexOf*[T](items: seq[T], value: T): TuckResult[int] =
  for tuck_i in (0 .. (len(items) - 1)):
    if true:
      if (tuck_rt.tuckAt(items, tuck_i) == value):
        if true:
          return tok(tuck_i)
  return tnone[int]()

proc tuck_insertAt*[T](items: seq[T], index: int, value: T): seq[T] =
  var tuck_out: seq[T] = @[]
  for tuck_i in (0 .. (len(items) - 1)):
    if true:
      if (tuck_i == index):
        if true:
          tuck_out.add(value)
      tuck_out.add(tuck_rt.tuckAt(items, tuck_i))
  if (index >= len(items)):
    if true:
      tuck_out.add(value)
  return tuck_out

proc tuck_removeAt*[T](items: seq[T], index: int): seq[T] =
  var tuck_out: seq[T] = @[]
  for tuck_i in (0 .. (len(items) - 1)):
    if true:
      if (tuck_i != index):
        if true:
          tuck_out.add(tuck_rt.tuckAt(items, tuck_i))
  return tuck_out

proc tuck_pop*[T](items: sink seq[T]): TuckResult[tuple[rest: seq[T], value: T]] =
  if (len(items) == 0):
    if true:
      return tnone[tuple[rest: seq[T], value: T]]()
  var tuck_top = tuck_rt.tuckAt(items, (len(items) - 1))
  var tuck_rest = tuck_removeAt(items, (len(items) - 1))
  return tok((rest: tuck_rest, value: tuck_top))

proc tuck_checkReads*(): int =
  var tuck_xs: seq[int] = @[10, 20, 30]
  if (tuck_count(tuck_xs) != 3):
    if true:
      return 1
  var tuck_empty: seq[int] = @[]
  if not tuck_isEmpty(tuck_empty):
    if true:
      return 2
  var tuck_got = tuckfn_at(tuck_xs, 1)
  if not tuck_got.ok:
    if true:
      return 3
  if (tuck_got.value != 20):
    if true:
      return 4
  var tuck_past = tuckfn_at(tuck_xs, 9)
  if tuck_past.ok:
    if true:
      return 5
  return tuck_checkEnds()

proc tuck_checkEnds*(): int =
  var tuck_xs: seq[int] = @[10, 20, 30]
  var tuck_f = tuck_first(tuck_xs)
  if not tuck_f.ok:
    if true:
      return 6
  if (tuck_f.value != 10):
    if true:
      return 7
  var tuck_l = tuck_last(tuck_xs)
  if not tuck_l.ok:
    if true:
      return 8
  if (tuck_l.value != 30):
    if true:
      return 9
  var tuck_empty: seq[int] = @[]
  var tuck_absent = tuck_first(tuck_empty)
  if tuck_absent.ok:
    if true:
      return 10
  return tuck_checkSearch()

proc tuck_checkSearch*(): int =
  var tuck_xs: seq[int] = @[10, 20, 30]
  if not tuck_has(tuck_xs, 20):
    if true:
      return 11
  if tuck_has(tuck_xs, 99):
    if true:
      return 12
  var tuck_idx = tuck_indexOf(tuck_xs, 30)
  if not tuck_idx.ok:
    if true:
      return 13
  if (tuck_idx.value != 2):
    if true:
      return 14
  var tuck_missing = tuck_indexOf(tuck_xs, 99)
  if tuck_missing.ok:
    if true:
      return 15
  return tuck_checkEdits()

proc tuck_checkEdits*(): int =
  var tuck_xs: seq[int] = @[10, 20, 30]
  var tuck_set = tuckfn_setAt(tuck_xs, 1, 99)
  if (tuck_rt.tuckAt(tuck_set, 1) != 99):
    if true:
      return 16
  if (tuck_rt.tuckAt(tuck_xs, 1) != 20):
    if true:
      return 17
  var tuck_ins = tuck_insertAt(tuck_xs, 1, 15)
  if (len(tuck_ins) != 4):
    if true:
      return 18
  if (tuck_rt.tuckAt(tuck_ins, 1) != 15):
    if true:
      return 19
  var tuck_del = tuck_removeAt(tuck_xs, 0)
  if (len(tuck_del) != 2):
    if true:
      return 20
  if (tuck_rt.tuckAt(tuck_del, 0) != 20):
    if true:
      return 21
  return tuck_checkPop()

proc tuck_checkPop*(): int =
  var tuck_xs: seq[int] = @[10, 20, 30]
  var tuck_p = tuck_pop(tuck_xs)
  if not tuck_p.ok:
    if true:
      return 22
  if (tuck_p.value.value != 30):
    if true:
      return 23
  if (tuck_p.value.rest.len != 2):
    if true:
      return 24
  var tuck_empty: seq[int] = @[]
  var tuck_absent = tuck_pop(tuck_empty)
  if tuck_absent.ok:
    if true:
      return 25
  var tuck_cleared = tuck_clear(tuck_xs)
  if (len(tuck_cleared) != 0):
    if true:
      return 26
  return 0

proc tuck_main*(): int =
  return tuck_checkReads()


when isMainModule:
  quit(tuck_main())
