{.experimental: "codeReordering".}
import ../../compiler/tuck_rt
import value

proc tuck_compare*[T](self: T, other: T): tuck_Order
proc tuck_equals*[T](self: T, other: T): bool
proc tuck_minOf*[T](a: T, b: T): T
proc tuck_maxOf*[T](a: T, b: T): T
proc tuck_clamped*[T](value: T, low: T, high: T): T
proc tuck_isBefore*[T](a: T, b: T): bool
proc tuck_isAfter*[T](a: T, b: T): bool
proc tuck_isSame*[T](a: T, b: T): bool
proc tuck_flipped*(o: tuck_Order): tuck_Order
proc tuck_breakTiesWith*(o: tuck_Order, next: tuck_Order): tuck_Order

proc tuck_compare*[T](self: T, other: T): tuck_Order =
  if (self < other):
    if true:
      return tuck_Order.Before
  if (self > other):
    if true:
      return tuck_Order.After
  return tuck_Order.Same

proc tuck_equals*[T](self: T, other: T): bool =
  return (self == other)

proc tuck_minOf*[T](a: T, b: T): T =
  var tuck_c = tuck_compare(a, b)
  (case tuck_c
  of After:
    return b
  else:
    return a)

proc tuck_maxOf*[T](a: T, b: T): T =
  var tuck_c = tuck_compare(a, b)
  (case tuck_c
  of Before:
    return b
  else:
    return a)

proc tuck_clamped*[T](value: T, low: T, high: T): T =
  var tuck_lifted = tuck_maxOf(value, low)
  return tuck_minOf(tuck_lifted, high)

proc tuck_isBefore*[T](a: T, b: T): bool =
  var tuck_c = tuck_compare(a, b)
  (case tuck_c
  of Before:
    return true
  else:
    return false)

proc tuck_isAfter*[T](a: T, b: T): bool =
  var tuck_c = tuck_compare(a, b)
  (case tuck_c
  of After:
    return true
  else:
    return false)

proc tuck_isSame*[T](a: T, b: T): bool =
  var tuck_c = tuck_compare(a, b)
  (case tuck_c
  of Same:
    return true
  else:
    return false)

proc tuck_flipped*(o: tuck_Order): tuck_Order =
  (case o
  of Before:
    return tuck_Order.After
  of Same:
    return tuck_Order.Same
  of After:
    return tuck_Order.Before)

proc tuck_breakTiesWith*(o: tuck_Order, next: tuck_Order): tuck_Order =
  (case o
  of Same:
    return next
  of Before:
    return tuck_Order.Before
  of After:
    return tuck_Order.After)

