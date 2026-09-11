{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq

proc tuck_map*[T, U](items: seq[T], f: tuck_Mapper[T, U]): seq[U]
proc tuck_filter*[T](items: seq[T], test: tuck_Predicate[T]): seq[T]
proc tuck_reject*[T](items: seq[T], test: tuck_Predicate[T]): seq[T]
proc tuck_take*[T](items: seq[T], n: int): seq[T]
proc tuck_skip*[T](items: seq[T], n: int): seq[T]
proc tuck_numbered*[T](items: seq[T]): seq[tuple[index: int, value: T]]
proc tuck_zip*[T, U](items: seq[T], other: seq[U]): seq[tuple[left: T, right: U]]
proc tuck_append*[T](items: sink seq[T], other: seq[T]): seq[T]
proc tuck_prepend*[T](items: seq[T], other: sink seq[T]): seq[T]
proc tuckfn_concat*[T](items: seq[seq[T]]): seq[T]
proc tuck_reverse*[T](items: seq[T]): seq[T]
proc tuck_reduce*[T, A](items: seq[T], start: A, combine: tuck_Combiner[T, A]): A
proc tuck_each*[T](items: seq[T], f: tuck_Action[T]): void
proc tuck_find*[T](items: seq[T], test: tuck_Predicate[T]): TuckResult[T]
proc tuck_any*[T](items: seq[T], test: tuck_Predicate[T]): bool
proc tuck_all*[T](items: seq[T], test: tuck_Predicate[T]): bool
proc tuck_sum*[T](items: seq[T]): TuckResult[T]
proc tuck_sort*[T](items: sink seq[T]): seq[T]
proc tuck_isPositive*(x: int): bool
proc tuck_double*(x: int): int
proc tuck_addUp*(acc: int, x: int): int
proc tuck_recordEach*(x: int): void
proc tuck_checkFilterMap*(): int
proc tuck_checkSlices*(): int
proc tuck_checkJoins*(): int
proc tuck_checkAdapters*(): int
proc tuck_checkReduceFind*(): int
proc tuck_checkPredicates*(): int
proc tuck_checkTerminals*(): int
proc tuck_checkOrder*(): int
proc tuck_main*(): int

type tuck_Mapper*[T, U] = proc(x: T): U {.closure.}

type tuck_Predicate*[T] = proc(x: T): bool {.closure.}

type tuck_Combiner*[T, A] = proc(acc: A, x: T): A {.closure.}

type tuck_Action*[T] = proc(x: T): void {.closure.}

proc tuck_map*[T, U](items: seq[T], f: tuck_Mapper[T, U]): seq[U] =
  var tuck_out: seq[U] = @[]
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      var tuck_v = f(tuck_rt.tuckAt(items, tuck_i))
      tuck_out.add(tuck_v)
  return tuck_out

proc tuck_filter*[T](items: seq[T], test: tuck_Predicate[T]): seq[T] =
  var tuck_out: seq[T] = @[]
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      var tuck_v = tuck_rt.tuckAt(items, tuck_i)
      if test(tuck_v):
        if true:
          tuck_out.add(tuck_v)
  return tuck_out

proc tuck_reject*[T](items: seq[T], test: tuck_Predicate[T]): seq[T] =
  var tuck_out: seq[T] = @[]
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      var tuck_v = tuck_rt.tuckAt(items, tuck_i)
      if not test(tuck_v):
        if true:
          tuck_out.add(tuck_v)
  return tuck_out

proc tuck_take*[T](items: seq[T], n: int): seq[T] =
  var tuck_out: seq[T] = @[]
  var tuck_i = 0
  while ((tuck_i < getLength(items)) and (tuck_i < n)):
    if true:
      tuck_out.add(tuck_rt.tuckAt(items, tuck_i))
      tuck_i = (tuck_i + 1)
  return tuck_out

proc tuck_skip*[T](items: seq[T], n: int): seq[T] =
  var tuck_out: seq[T] = @[]
  var tuck_i = n
  while (tuck_i < getLength(items)):
    if true:
      tuck_out.add(tuck_rt.tuckAt(items, tuck_i))
      tuck_i = (tuck_i + 1)
  return tuck_out

proc tuck_numbered*[T](items: seq[T]): seq[tuple[index: int, value: T]] =
  var tuck_out: seq[tuple[index: int, value: T]] = @[]
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      tuck_out.add((index: tuck_i, value: tuck_rt.tuckAt(items, tuck_i)))
  return tuck_out

proc tuck_zip*[T, U](items: seq[T], other: seq[U]): seq[tuple[left: T, right: U]] =
  var tuck_out: seq[tuple[left: T, right: U]] = @[]
  var tuck_n = getLength(items)
  if (getLength(other) < tuck_n):
    if true:
      tuck_n = getLength(other)
  var tuck_i = 0
  while (tuck_i < tuck_n):
    if true:
      tuck_out.add((left: tuck_rt.tuckAt(items, tuck_i), right: tuck_rt.tuckAt(other, tuck_i)))
      tuck_i = (tuck_i + 1)
  return tuck_out

proc tuck_append*[T](items: sink seq[T], other: seq[T]): seq[T] =
  var tuck_out = items
  for tuck_i in (0 .. (getLength(other) - 1)):
    if true:
      tuck_out.add(tuck_rt.tuckAt(other, tuck_i))
  return tuck_out

proc tuck_prepend*[T](items: seq[T], other: sink seq[T]): seq[T] =
  var tuck_out = other
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      tuck_out.add(tuck_rt.tuckAt(items, tuck_i))
  return tuck_out

proc tuckfn_concat*[T](items: seq[seq[T]]): seq[T] =
  var tuck_out: seq[T] = @[]
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      var tuck_inner = tuck_rt.tuckAt(items, tuck_i)
      for tuck_j in (0 .. (getLength(tuck_inner) - 1)):
        if true:
          tuck_out.add(tuck_rt.tuckAt(tuck_inner, tuck_j))
  return tuck_out

proc tuck_reverse*[T](items: seq[T]): seq[T] =
  var tuck_out: seq[T] = @[]
  var tuck_i = (getLength(items) - 1)
  while (tuck_i >= 0):
    if true:
      tuck_out.add(tuck_rt.tuckAt(items, tuck_i))
      tuck_i = (tuck_i - 1)
  return tuck_out

proc tuck_reduce*[T, A](items: seq[T], start: A, combine: tuck_Combiner[T, A]): A =
  var tuck_acc = start
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      tuck_acc = combine(tuck_acc, tuck_rt.tuckAt(items, tuck_i))
  return tuck_acc

proc tuck_each*[T](items: seq[T], f: tuck_Action[T]): void =
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      f(tuck_rt.tuckAt(items, tuck_i))

proc tuck_find*[T](items: seq[T], test: tuck_Predicate[T]): TuckResult[T] =
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      var tuck_v = tuck_rt.tuckAt(items, tuck_i)
      if test(tuck_v):
        if true:
          return tok(tuck_v)
  return tnone[T]()

proc tuck_any*[T](items: seq[T], test: tuck_Predicate[T]): bool =
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      if test(tuck_rt.tuckAt(items, tuck_i)):
        if true:
          return true
  return false

proc tuck_all*[T](items: seq[T], test: tuck_Predicate[T]): bool =
  for tuck_i in (0 .. (getLength(items) - 1)):
    if true:
      if not test(tuck_rt.tuckAt(items, tuck_i)):
        if true:
          return false
  return true

proc tuck_sum*[T](items: seq[T]): TuckResult[T] =
  if (getLength(items) == 0):
    if true:
      return tnone[T]()
  var tuck_acc = tuck_rt.tuckAt(items, 0)
  for tuck_i in (1 .. (getLength(items) - 1)):
    if true:
      tuck_acc = (tuck_acc + tuck_rt.tuckAt(items, tuck_i))
  return tok(tuck_acc)

proc tuck_sort*[T](items: sink seq[T]): seq[T] =
  var tuck_out = items
  var tuck_i = 1
  while (tuck_i < getLength(tuck_out)):
    if true:
      var tuck_key = tuck_rt.tuckAt(tuck_out, tuck_i)
      var tuck_j = (tuck_i - 1)
      while ((tuck_j >= 0) and (tuck_rt.tuckAt(tuck_out, tuck_j) > tuck_key)):
        if true:
          tuck_rt.setAt(tuck_out, (tuck_j + 1), tuck_rt.tuckAt(tuck_out, tuck_j))
          tuck_j = (tuck_j - 1)
      tuck_rt.setAt(tuck_out, (tuck_j + 1), tuck_key)
      tuck_i = (tuck_i + 1)
  return tuck_out

proc tuck_isPositive*(x: int): bool =
  return (x > 0)

proc tuck_double*(x: int): int =
  return (x * 2)

proc tuck_addUp*(acc: int, x: int): int =
  return (acc + x)

proc tuck_recordEach*(x: int): void =
  return

proc tuck_checkFilterMap*(): int =
  var tuck_xs: seq[int] = @[(0 - 3), 1, 4, (0 - 1), 5, 9]
  var tuck_live = tuck_filter(tuck_xs, tuck_isPositive)
  if (getLength(tuck_live) != 4):
    if true:
      return 1
  var tuck_doubled = tuck_map(tuck_live, tuck_double)
  if ((tuck_rt.tuckAt(tuck_doubled, 0) != 2) or (tuck_rt.tuckAt(tuck_doubled, 3) != 18)):
    if true:
      return 2
  var tuck_gone = tuck_reject(tuck_xs, tuck_isPositive)
  if (getLength(tuck_gone) != 2):
    if true:
      return 3
  return 0

proc tuck_checkSlices*(): int =
  var tuck_xs: seq[int] = @[(0 - 3), 1, 4, (0 - 1), 5, 9]
  var tuck_first2 = tuck_take(tuck_xs, 2)
  if ((getLength(tuck_first2) != 2) or (tuck_rt.tuckAt(tuck_first2, 1) != 1)):
    if true:
      return 4
  var tuck_rest = tuck_skip(tuck_xs, 2)
  if ((getLength(tuck_rest) != (getLength(tuck_xs) - 2)) or (tuck_rt.tuckAt(tuck_rest, 0) != 4)):
    if true:
      return 5
  var tuck_nums = tuck_numbered(tuck_xs)
  if ((tuck_rt.tuckAt(tuck_nums, 0).index != 0) or (tuck_rt.tuckAt(tuck_nums, 2).value != 4)):
    if true:
      return 6
  return 0

proc tuck_checkJoins*(): int =
  var tuck_xs: seq[int] = @[(0 - 3), 1, 4, (0 - 1), 5, 9]
  var tuck_first2 = tuck_take(tuck_xs, 2)
  var tuck_rest = tuck_skip(tuck_xs, 2)
  var tuck_ys: seq[int] = @[10, 20]
  var tuck_paired = tuck_zip(tuck_xs, tuck_ys)
  if ((getLength(tuck_paired) != 2) or ((tuck_rt.tuckAt(tuck_paired, 1).left != 1) or (tuck_rt.tuckAt(tuck_paired, 1).right != 20))):
    if true:
      return 7
  var tuck_joined = tuck_append(tuck_first2, tuck_rest)
  if (getLength(tuck_joined) != getLength(tuck_xs)):
    if true:
      return 8
  var tuck_front = tuck_prepend(tuck_rest, tuck_first2)
  if ((getLength(tuck_front) != getLength(tuck_xs)) or (tuck_rt.tuckAt(tuck_front, 0) != tuck_rt.tuckAt(tuck_first2, 0))):
    if true:
      return 9
  var tuck_nested: seq[seq[int]] = @[tuck_first2, tuck_rest]
  var tuck_flat = tuckfn_concat(tuck_nested)
  if (getLength(tuck_flat) != getLength(tuck_xs)):
    if true:
      return 10
  var tuck_backwards = tuck_reverse(tuck_first2)
  if ((tuck_rt.tuckAt(tuck_backwards, 0) != tuck_rt.tuckAt(tuck_first2, 1)) or (tuck_rt.tuckAt(tuck_backwards, 1) != tuck_rt.tuckAt(tuck_first2, 0))):
    if true:
      return 11
  return 0

proc tuck_checkAdapters*(): int =
  var tuck_a = tuck_checkFilterMap()
  if (tuck_a != 0):
    if true:
      return tuck_a
  var tuck_b = tuck_checkSlices()
  if (tuck_b != 0):
    if true:
      return tuck_b
  return tuck_checkJoins()

proc tuck_checkReduceFind*(): int =
  var tuck_xs: seq[int] = @[(0 - 3), 1, 4, (0 - 1), 5, 9]
  var tuck_total = tuck_reduce(tuck_xs, 0, tuck_addUp)
  if (tuck_total != 15):
    if true:
      return 20
  tuck_each(tuck_xs, tuck_recordEach)
  var tuck_hit = tuck_find(tuck_xs, tuck_isPositive)
  if not tuck_hit.ok:
    if true:
      return 21
  if (tuck_hit.value != 1):
    if true:
      return 21
  var tuck_noneHit = tuck_find(@[(0 - 1), (0 - 2)], tuck_isPositive)
  if tuck_noneHit.ok:
    if true:
      return 22
  return 0

proc tuck_checkPredicates*(): int =
  var tuck_xs: seq[int] = @[(0 - 3), 1, 4, (0 - 1), 5, 9]
  if not tuck_any(tuck_xs, tuck_isPositive):
    if true:
      return 23
  if tuck_all(tuck_xs, tuck_isPositive):
    if true:
      return 24
  var tuck_miss = tuck_filter(tuck_xs, tuck_isPositive)
  var tuck_total = tuck_sum(tuck_miss)
  if not tuck_total.ok:
    if true:
      return 25
  if (tuck_total.value != 19):
    if true:
      return 25
  var tuck_noItems: seq[int] = @[]
  var tuck_emptySum = tuck_sum(tuck_noItems)
  if tuck_emptySum.ok:
    if true:
      return 26
  return 0

proc tuck_checkTerminals*(): int =
  var tuck_a = tuck_checkReduceFind()
  if (tuck_a != 0):
    if true:
      return tuck_a
  return tuck_checkPredicates()

proc tuck_checkOrder*(): int =
  var tuck_xs: seq[int] = @[5, 3, (0 - 1), 4, 4, 9, 0]
  var tuck_sorted = tuck_sort(tuck_xs)
  var tuck_i = 1
  while (tuck_i < getLength(tuck_sorted)):
    if true:
      if (tuck_rt.tuckAt(tuck_sorted, (tuck_i - 1)) > tuck_rt.tuckAt(tuck_sorted, tuck_i)):
        if true:
          return 30
      tuck_i = (tuck_i + 1)
  if ((tuck_rt.tuckAt(tuck_sorted, 0) != (0 - 1)) or (tuck_rt.tuckAt(tuck_sorted, (getLength(tuck_sorted) - 1)) != 9)):
    if true:
      return 31
  return 0

proc tuck_main*(): int =
  var tuck_a = tuck_checkAdapters()
  if (tuck_a != 0):
    if true:
      return tuck_a
  var tuck_t = tuck_checkTerminals()
  if (tuck_t != 0):
    if true:
      return tuck_t
  return tuck_checkOrder()


when isMainModule:
  quit(tuck_main())
