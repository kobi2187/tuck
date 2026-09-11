{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq

proc tuck_has*[T](s: tuck_Set[T], value: T): bool
proc tuck_count*[T](s: sink tuck_Set[T]): int
proc tuck_toSeq*[T](s: sink tuck_Set[T]): seq[T]
proc tuck_add*[T](s: sink tuck_Set[T], value: T): tuck_Set[T]
proc tuck_remove*[T](s: tuck_Set[T], value: T): tuck_Set[T]
proc tuck_union*[T](a: sink tuck_Set[T], b: tuck_Set[T]): tuck_Set[T]
proc tuck_intersect*[T](a: tuck_Set[T], b: tuck_Set[T]): tuck_Set[T]
proc tuck_difference*[T](a: tuck_Set[T], b: tuck_Set[T]): tuck_Set[T]
proc tuck_threeWords*(): tuck_Set[string]
proc tuck_checkBasics*(): int
proc tuck_checkRemove*(): int
proc tuck_twoOnly*(): tuck_Set[string]
proc tuck_checkAlgebra*(): int
proc tuck_checkDifference*(a: sink tuck_Set[string], b: sink tuck_Set[string]): int
proc tuck_main*(): int

type tuck_Set*[T] = object
  items*: seq[T]

proc tuck_has*[T](s: tuck_Set[T], value: T): bool =
  for tuck_i in (0 .. (s.items.len - 1)):
    if true:
      if (tuck_rt.tuckAt(s.items, tuck_i) == value):
        if true:
          return true
  return false

proc tuck_count*[T](s: sink tuck_Set[T]): int =
  return s.items.len

proc tuck_toSeq*[T](s: sink tuck_Set[T]): seq[T] =
  return s.items

proc tuck_add*[T](s: sink tuck_Set[T], value: T): tuck_Set[T] =
  if tuck_has(s, value):
    if true:
      return s
  return tuck_Set[T](items: tuck_rt.push(s.items, value))

proc tuck_remove*[T](s: tuck_Set[T], value: T): tuck_Set[T] =
  var tuck_kept: seq[T] = @[]
  for tuck_i in (0 .. (s.items.len - 1)):
    if true:
      var tuck_item = tuck_rt.tuckAt(s.items, tuck_i)
      if (tuck_item != value):
        if true:
          tuck_kept.add(tuck_item)
  return tuck_Set[T](items: tuck_kept)

proc tuck_union*[T](a: sink tuck_Set[T], b: tuck_Set[T]): tuck_Set[T] =
  var tuck_out = a
  for tuck_i in (0 .. (b.items.len - 1)):
    if true:
      tuck_out = tuck_add(tuck_out, tuck_rt.tuckAt(b.items, tuck_i))
  return tuck_out

proc tuck_intersect*[T](a: tuck_Set[T], b: tuck_Set[T]): tuck_Set[T] =
  var tuck_out: tuck_Set[T] = tuck_Set[T](items: @[])
  for tuck_i in (0 .. (a.items.len - 1)):
    if true:
      var tuck_item = tuck_rt.tuckAt(a.items, tuck_i)
      if tuck_has(b, tuck_item):
        if true:
          tuck_out = tuck_add(tuck_out, tuck_item)
  return tuck_out

proc tuck_difference*[T](a: tuck_Set[T], b: tuck_Set[T]): tuck_Set[T] =
  var tuck_out: tuck_Set[T] = tuck_Set[T](items: @[])
  for tuck_i in (0 .. (a.items.len - 1)):
    if true:
      var tuck_item = tuck_rt.tuckAt(a.items, tuck_i)
      if not tuck_has(b, tuck_item):
        if true:
          tuck_out = tuck_add(tuck_out, tuck_item)
  return tuck_out

proc tuck_threeWords*(): tuck_Set[string] =
  var tuck_s: tuck_Set[string] = tuck_Set[string](items: @[])
  tuck_s = tuck_add(tuck_s, "a")
  tuck_s = tuck_add(tuck_s, "b")
  return tuck_add(tuck_s, "c")

proc tuck_checkBasics*(): int =
  var tuck_s: tuck_Set[string] = tuck_Set[string](items: @[])
  tuck_s = tuck_add(tuck_s, "a")
  tuck_s = tuck_add(tuck_s, "a")
  if (tuck_count(tuck_s) != 1):
    if true:
      return 1
  if not tuck_has(tuck_s, "a"):
    if true:
      return 2
  if tuck_has(tuck_s, "z"):
    if true:
      return 3
  return tuck_checkRemove()

proc tuck_checkRemove*(): int =
  var tuck_s = tuck_threeWords()
  if (tuck_count(tuck_s) != 3):
    if true:
      return 4
  tuck_s = tuck_remove(tuck_s, "b")
  if (tuck_count(tuck_s) != 2):
    if true:
      return 5
  if tuck_has(tuck_s, "b"):
    if true:
      return 6
  tuck_s = tuck_remove(tuck_s, "zzz")
  if (tuck_count(tuck_s) != 2):
    if true:
      return 7
  return 0

proc tuck_twoOnly*(): tuck_Set[string] =
  var tuck_t: tuck_Set[string] = tuck_Set[string](items: @[])
  tuck_t = tuck_add(tuck_t, "b")
  return tuck_add(tuck_t, "d")

proc tuck_checkAlgebra*(): int =
  var tuck_a = tuck_threeWords()
  var tuck_b = tuck_twoOnly()
  var tuck_both = tuck_union(tuck_a, tuck_b)
  if (tuck_count(tuck_both) != 4):
    if true:
      return 8
  var tuck_common = tuck_intersect(tuck_a, tuck_b)
  if (tuck_count(tuck_common) != 1):
    if true:
      return 9
  if not tuck_has(tuck_common, "b"):
    if true:
      return 10
  return tuck_checkDifference(tuck_a, tuck_b)

proc tuck_checkDifference*(a: sink tuck_Set[string], b: sink tuck_Set[string]): int =
  var tuck_only = tuck_difference(a, b)
  if (tuck_count(tuck_only) != 2):
    if true:
      return 11
  if tuck_has(tuck_only, "b"):
    if true:
      return 12
  if not tuck_has(tuck_only, "a"):
    if true:
      return 13
  var tuck_other = tuck_difference(b, a)
  if (tuck_count(tuck_other) != 1):
    if true:
      return 14
  var tuck_seq = tuck_toSeq(tuck_other)
  if (tuck_seq.len != 1):
    if true:
      return 15
  return 0

proc tuck_main*(): int =
  var tuck_basics = tuck_checkBasics()
  if (tuck_basics != 0):
    if true:
      return tuck_basics
  return tuck_checkAlgebra()


when isMainModule:
  quit(tuck_main())
