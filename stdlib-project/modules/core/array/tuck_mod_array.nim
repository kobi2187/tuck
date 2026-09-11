{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
export tuck_rt
import seq as tuck_mod_seq

proc tuck_atFixed*[N, T](items: array[N, T], index: int): TuckResult[T]
proc tuck_setAtFixed*[N, T](items: array[N, T], index: int, value: T): TuckResult[array[N, T]]
proc tuck_countOf*[T](items: seq[T], value: T): int
proc tuck_chunk*[T](items: seq[T], size: int): seq[seq[T]]
proc tuck_checkAccess*(): int
proc tuck_checkCountAndChunk*(): int
proc tuck_main*(): int

type tuck_Board* = object
  cells*: array[4, int]

proc tuck_atFixed*[N, T](items: array[N, T], index: int): TuckResult[T] =
  var tuck_n = getLength(items)
  if ((index < 0) or (index >= tuck_n)):
    if true:
      return tnone[T]()
  return tok(tuckArrayAt(items, index))

proc tuck_setAtFixed*[N, T](items: array[N, T], index: int, value: T): TuckResult[array[N, T]] =
  var tuck_out = items
  if ((index < 0) or (index >= getLength(tuck_out))):
    if true:
      return TuckResult[array[N, T]](status: tsAbsent)
  tuckArraySetAt(tuck_out, index, value)
  return tok(tuck_out)

proc tuck_countOf*[T](items: seq[T], value: T): int =
  var tuck_n = 0
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      if (tuck_rt.tuckAt(items, tuck_i) == value):
        if true:
          tuck_n = (tuck_n + 1)
  return tuck_n

proc tuck_chunk*[T](items: seq[T], size: int): seq[seq[T]] =
  var tuck_out: seq[seq[T]] = @[]
  if (size <= 0):
    if true:
      return tuck_out
  var tuck_i = 0
  while (tuck_i < getLength(items)):
    if true:
      var tuck_piece: seq[T] = @[]
      var tuck_j = tuck_i
      while ((tuck_j < getLength(items)) and (tuck_j < (tuck_i + size))):
        if true:
          tuck_piece.add(tuck_rt.tuckAt(items, tuck_j))
          tuck_j = (tuck_j + 1)
      tuck_out.add(tuck_piece)
      tuck_i = (tuck_i + size)
  return tuck_out

proc tuck_checkAccess*(): int =
  var tuck_b = tuck_Board(cells: [10, 20, 30, 40])
  var tuck_r0 = tuck_atFixed(tuck_b.cells, 0)
  if not tuck_r0.ok:
    if true:
      return 1
  if (tuck_r0.value != 10):
    if true:
      return 2
  var tuck_bad = tuck_atFixed(tuck_b.cells, 99)
  if tuck_bad.ok:
    if true:
      return 3
  var tuck_wrote = tuck_setAtFixed(tuck_b.cells, 1, 99)
  if not tuck_wrote.ok:
    if true:
      return 4
  var tuck_r1 = tuck_atFixed(tuck_wrote.value, 1)
  if not tuck_r1.ok:
    if true:
      return 5
  if (tuck_r1.value != 99):
    if true:
      return 6
  var tuck_failedWrite = tuck_setAtFixed(tuck_b.cells, (0 - 1), 5)
  if tuck_failedWrite.ok:
    if true:
      return 7
  return 0

proc tuck_checkCountAndChunk*(): int =
  var tuck_xs: seq[int] = @[1, 2, 2, 3, 2, 4]
  if (tuck_countOf(tuck_xs, 2) != 3):
    if true:
      return 10
  if (tuck_countOf(tuck_xs, 9) != 0):
    if true:
      return 11
  var tuck_parts = tuck_chunk(tuck_xs, 4)
  if (getLength(tuck_parts) != 2):
    if true:
      return 12
  if ((tuck_rt.tuckAt(tuck_parts, 0).len != 4) or (tuck_rt.tuckAt(tuck_parts, 1).len != 2)):
    if true:
      return 13
  if ((tuck_rt.tuckAt(tuck_rt.tuckAt(tuck_parts, 1), 0) != 2) or (tuck_rt.tuckAt(tuck_rt.tuckAt(tuck_parts, 1), 1) != 4)):
    if true:
      return 14
  var tuck_empty: seq[int] = @[]
  var tuck_emptyChunks = tuck_chunk(tuck_empty, 3)
  if (getLength(tuck_emptyChunks) != 0):
    if true:
      return 15
  return 0

proc tuck_main*(): int =
  var tuck_a = tuck_checkAccess()
  if (tuck_a != 0):
    if true:
      return tuck_a
  return tuck_checkCountAndChunk()


when isMainModule:
  quit(tuck_main())
