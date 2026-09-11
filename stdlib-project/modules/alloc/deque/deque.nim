{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq

proc tuck_count*[T](r: sink tuck_Ring[T]): int
proc tuck_isEmpty*[T](r: sink tuck_Ring[T]): bool
proc tuck_first*[T](r: sink tuck_Ring[T]): TuckResult[T]
proc tuck_last*[T](r: sink tuck_Ring[T]): TuckResult[T]
proc tuck_pushBack*[T](r: sink tuck_Ring[T], value: T): tuck_Ring[T]
proc tuck_pushFront*[T](r: tuck_Ring[T], value: T): tuck_Ring[T]
proc tuck_popBack*[T](r: tuck_Ring[T]): TuckResult[tuple[rest: tuck_Ring[T], value: T]]
proc tuck_popFront*[T](r: tuck_Ring[T]): TuckResult[tuple[rest: tuck_Ring[T], value: T]]
proc tuck_clear*[T](r: tuck_Ring[T]): tuck_Ring[T]
proc tuck_toSeq*[T](r: sink tuck_Ring[T]): seq[T]
proc tuck_checkEnds*(): int
proc tuck_threeUp*(): tuck_Ring[int]
proc tuck_checkPops*(): int
proc tuck_checkEmptyPops*(): int
proc tuck_main*(): int

type tuck_Ring*[T] = object
  items*: seq[T]

proc tuck_count*[T](r: sink tuck_Ring[T]): int =
  return r.items.len

proc tuck_isEmpty*[T](r: sink tuck_Ring[T]): bool =
  return (r.items.len == 0)

proc tuck_first*[T](r: sink tuck_Ring[T]): TuckResult[T] =
  if (r.items.len == 0):
    if true:
      return tnone[T]()
  return tok(tuck_rt.tuckAt(r.items, 0))

proc tuck_last*[T](r: sink tuck_Ring[T]): TuckResult[T] =
  if (r.items.len == 0):
    if true:
      return tnone[T]()
  return tok(tuck_rt.tuckAt(r.items, (r.items.len - 1)))

proc tuck_pushBack*[T](r: sink tuck_Ring[T], value: T): tuck_Ring[T] =
  var tuck_xs = r.items
  tuck_xs.add(value)
  return tuck_Ring[T](items: tuck_xs)

proc tuck_pushFront*[T](r: tuck_Ring[T], value: T): tuck_Ring[T] =
  var tuck_xs: seq[T] = @[]
  tuck_xs.add(value)
  for tuck_i in (0 .. (r.items.len - 1)):
    if true:
      tuck_xs.add(tuck_rt.tuckAt(r.items, tuck_i))
  return tuck_Ring[T](items: tuck_xs)

proc tuck_popBack*[T](r: tuck_Ring[T]): TuckResult[tuple[rest: tuck_Ring[T], value: T]] =
  var tuck_n = r.items.len
  if (tuck_n == 0):
    if true:
      return tnone[tuple[rest: tuck_Ring[T], value: T]]()
  var tuck_top = tuck_rt.tuckAt(r.items, (tuck_n - 1))
  var tuck_xs: seq[T] = @[]
  for tuck_i in (0 .. (tuck_n - 2)):
    if true:
      tuck_xs.add(tuck_rt.tuckAt(r.items, tuck_i))
  var tuck_rest = tuck_Ring[T](items: tuck_xs)
  return tok((rest: tuck_rest, value: tuck_top))

proc tuck_popFront*[T](r: tuck_Ring[T]): TuckResult[tuple[rest: tuck_Ring[T], value: T]] =
  var tuck_n = r.items.len
  if (tuck_n == 0):
    if true:
      return tnone[tuple[rest: tuck_Ring[T], value: T]]()
  var tuck_head = tuck_rt.tuckAt(r.items, 0)
  var tuck_xs: seq[T] = @[]
  for tuck_i in (1 .. (tuck_n - 1)):
    if true:
      tuck_xs.add(tuck_rt.tuckAt(r.items, tuck_i))
  var tuck_rest = tuck_Ring[T](items: tuck_xs)
  return tok((rest: tuck_rest, value: tuck_head))

proc tuck_clear*[T](r: tuck_Ring[T]): tuck_Ring[T] =
  var tuck_empty: seq[T] = @[]
  return tuck_Ring[T](items: tuck_empty)

proc tuck_toSeq*[T](r: sink tuck_Ring[T]): seq[T] =
  return r.items

proc tuck_checkEnds*(): int =
  var tuck_q: tuck_Ring[int] = tuck_Ring[int](items: @[])
  if not tuck_isEmpty(tuck_q):
    if true:
      return 1
  var tuck_noEnd = tuck_first(tuck_q)
  if tuck_noEnd.ok:
    if true:
      return 2
  tuck_q = tuck_pushBack(tuck_q, 2)
  tuck_q = tuck_pushBack(tuck_q, 3)
  tuck_q = tuck_pushFront(tuck_q, 1)
  if (tuck_count(tuck_q) != 3):
    if true:
      return 3
  var tuck_f = tuck_first(tuck_q)
  if not tuck_f.ok:
    if true:
      return 4
  if (tuck_f.value != 1):
    if true:
      return 5
  var tuck_l = tuck_last(tuck_q)
  if not tuck_l.ok:
    if true:
      return 6
  if (tuck_l.value != 3):
    if true:
      return 7
  return tuck_checkPops()

proc tuck_threeUp*(): tuck_Ring[int] =
  var tuck_q: tuck_Ring[int] = tuck_Ring[int](items: @[])
  tuck_q = tuck_pushBack(tuck_q, 1)
  tuck_q = tuck_pushBack(tuck_q, 2)
  return tuck_pushBack(tuck_q, 3)

proc tuck_checkPops*(): int =
  var tuck_q = tuck_threeUp()
  var tuck_back = tuck_popBack(tuck_q)
  if not tuck_back.ok:
    if true:
      return 8
  if (tuck_back.value.value != 3):
    if true:
      return 9
  if (tuck_count(tuck_back.value.rest) != 2):
    if true:
      return 10
  var tuck_front = tuck_popFront(tuck_q)
  if not tuck_front.ok:
    if true:
      return 11
  if (tuck_front.value.value != 1):
    if true:
      return 12
  if (tuck_count(tuck_front.value.rest) != 2):
    if true:
      return 13
  if (tuck_count(tuck_q) != 3):
    if true:
      return 14
  return tuck_checkEmptyPops()

proc tuck_checkEmptyPops*(): int =
  var tuck_empty: tuck_Ring[int] = tuck_Ring[int](items: @[])
  var tuck_b = tuck_popBack(tuck_empty)
  if tuck_b.ok:
    if true:
      return 15
  var tuck_f = tuck_popFront(tuck_empty)
  if tuck_f.ok:
    if true:
      return 16
  var tuck_cleared = tuck_clear(tuck_threeUp())
  if (tuck_count(tuck_cleared) != 0):
    if true:
      return 17
  var tuck_xs = tuck_toSeq(tuck_threeUp())
  if (tuck_xs.len != 3):
    if true:
      return 18
  if (tuck_rt.tuckAt(tuck_xs, 0) != 1):
    if true:
      return 19
  return 0

proc tuck_main*(): int =
  return tuck_checkEnds()


when isMainModule:
  quit(tuck_main())
