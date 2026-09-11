{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt

proc tuck_flipped*(o: tuck_Order): tuck_Order
proc tuck_breakTiesWith*(o: tuck_Order, next: tuck_Order): tuck_Order
proc tuck_isBefore*(o: tuck_Order): bool
proc tuck_smaller*[T](a: T, b: T): T
proc tuck_larger*[T](a: T, b: T): T
proc tuck_clamped*[T](x: T, low: T, high: T): T
proc tuck_main*(): int

type tuck_Order* = enum Before, Same, After

# interface Sortable: no satisfying types

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

proc tuck_isBefore*(o: tuck_Order): bool =
  (case o
  of Before:
    return true
  of Same:
    return false
  of After:
    return false)

proc tuck_smaller*[T](a: T, b: T): T =
  if (a < b):
    if true:
      return a
  return b

proc tuck_larger*[T](a: T, b: T): T =
  if (a < b):
    if true:
      return b
  return a

proc tuck_clamped*[T](x: T, low: T, high: T): T =
  if (x < low):
    if true:
      return low
  if (high < x):
    if true:
      return high
  return x

proc tuck_main*(): int =
  var tuck_f = tuck_flipped(tuck_Order.Before)
  var tuck_t = tuck_breakTiesWith(tuck_Order.Same, tuck_Order.After)
  if tuck_isBefore(tuck_f):
    if true:
      return 1
  if tuck_isBefore(tuck_t):
    if true:
      return 2
  var tuck_s = tuck_smaller(3, 9)
  var tuck_l = tuck_larger(3, 9)
  var tuck_c = tuck_clamped(42, 0, 10)
  return (((tuck_s + tuck_l) - tuck_c) - 2)


when isMainModule:
  quit(tuck_main())
