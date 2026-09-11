{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import str

proc tuck_i64Max*(): int64
proc tuck_i64Min*(): int64
proc tuck_i32Max*(): int64
proc tuck_i32Min*(): int64
proc tuck_toNarrow*(x: int64): TuckResult[int32]
proc tuck_toNarrowClamped*(x: int64): int32
proc tuck_toApprox*(x: float): float32
proc tuck_digitOf*(t: sink string, index: int): TuckResult[int]
proc tuck_isSign*(t: sink string, index: int): bool
proc tuck_isNegative*(t: sink string): bool
proc tuck_parseInt*(t: sink string): TuckResult[int64]
proc tuck_accumulate*(t: string, start: int, count: int, neg: bool): TuckResult[int64]
proc tuck_addDigit*(acc: int64, digit: int, neg: bool): TuckResult[int64]
proc tuck_checkNarrow*(): int
proc tuck_checkParseOk*(): int
proc tuck_checkParseEdges*(): int
proc tuck_checkParseBad*(): int
proc tuck_main*(): int

proc tuck_i64Max*(): int64 =
  return 9223372036854775807'i64

proc tuck_i64Min*(): int64 =
  return ((0'i64 - tuck_i64Max()) - 1'i64)

proc tuck_i32Max*(): int64 =
  return 2147483647'i64

proc tuck_i32Min*(): int64 =
  return ((0'i64 - tuck_i32Max()) - 1'i64)

proc tuck_toNarrow*(x: int64): TuckResult[int32] =
  if ((x < tuck_i32Min()) or (x > tuck_i32Max())):
    if true:
      return tnone[int32]()
  return tok(int32(x))

proc tuck_toNarrowClamped*(x: int64): int32 =
  if (x < tuck_i32Min()):
    if true:
      return int32(tuck_i32Min())
  if (x > tuck_i32Max()):
    if true:
      return int32(tuck_i32Max())
  return int32(x)

proc tuck_toApprox*(x: float): float32 =
  return float32(x)

proc tuck_digitOf*(t: sink string, index: int): TuckResult[int] =
  var tuck_raw = tuck_rt.byteAt(t, index)
  var tuck_b = int(tuck_raw)
  if ((tuck_b < 48) or (tuck_b > 57)):
    if true:
      return tnone[int]()
  return tok((tuck_b - 48))

proc tuck_isSign*(t: sink string, index: int): bool =
  var tuck_raw = tuck_rt.byteAt(t, index)
  var tuck_b = int(tuck_raw)
  return ((tuck_b == 43) or (tuck_b == 45))

proc tuck_isNegative*(t: sink string): bool =
  if (tuck_rt.byteCount(t) == 0):
    if true:
      return false
  var tuck_lead = tuck_rt.byteAt(t, 0)
  return (int(tuck_lead) == 45)

proc tuck_parseInt*(t: sink string): TuckResult[int64] =
  var tuck_n = tuck_rt.byteCount(t)
  if (tuck_n == 0):
    if true:
      return tnone[int64]()
  var tuck_start = 0
  if tuck_isSign(t, 0):
    if true:
      tuck_start = 1
  if (tuck_start >= tuck_n):
    if true:
      return tnone[int64]()
  var tuck_neg = tuck_isNegative(t)
  return tuck_accumulate(t, tuck_start, tuck_n, tuck_neg)

proc tuck_accumulate*(t: string, start: int, count: int, neg: bool): TuckResult[int64] =
  var tuck_acc: int64 = 0'i64
  for tuck_i in (start .. (count - 1)):
    if true:
      var tuck_d = tuck_digitOf(t, tuck_i)
      if not tuck_d.ok:
        if true:
          return tnone[int64]()
      var tuck_step = tuck_addDigit(tuck_acc, tuck_d.value, neg)
      if not tuck_step.ok:
        if true:
          return tnone[int64]()
      tuck_acc = tuck_step.value
  return tok(tuck_acc)

proc tuck_addDigit*(acc: int64, digit: int, neg: bool): TuckResult[int64] =
  var tuck_d = int64(digit)
  if neg:
    if true:
      if (acc < ((tuck_i64Min() + tuck_d) div 10)):
        if true:
          return tnone[int64]()
      return tok(((acc * 10'i64) - tuck_d))
  if (acc > ((tuck_i64Max() - tuck_d) div 10)):
    if true:
      return tnone[int64]()
  return tok(((acc * 10'i64) + tuck_d))

proc tuck_checkNarrow*(): int =
  var tuck_ok = tuck_toNarrow(1000'i64)
  if not tuck_ok.ok:
    if true:
      return 1
  if (int(tuck_ok.value) != 1000):
    if true:
      return 2
  var tuck_past = tuck_toNarrow(3000000000'i64)
  if tuck_past.ok:
    if true:
      return 3
  var tuck_hi = tuck_toNarrowClamped(3000000000'i64)
  if (int64(tuck_hi) != tuck_i32Max()):
    if true:
      return 4
  var tuck_lo = tuck_toNarrowClamped((0'i64 - 3000000000'i64))
  if (int64(tuck_lo) != tuck_i32Min()):
    if true:
      return 5
  return tuck_checkParseOk()

proc tuck_checkParseOk*(): int =
  var tuck_a = tuck_parseInt("123")
  if not tuck_a.ok:
    if true:
      return 6
  if (tuck_a.value != 123):
    if true:
      return 7
  var tuck_b = tuck_parseInt("-45")
  if not tuck_b.ok:
    if true:
      return 8
  if (tuck_b.value != (0 - 45)):
    if true:
      return 9
  var tuck_c = tuck_parseInt("+7")
  if not tuck_c.ok:
    if true:
      return 10
  if (tuck_c.value != 7):
    if true:
      return 11
  return tuck_checkParseEdges()

proc tuck_checkParseEdges*(): int =
  var tuck_lo = tuck_parseInt("-9223372036854775808")
  if not tuck_lo.ok:
    if true:
      return 12
  if (tuck_lo.value != tuck_i64Min()):
    if true:
      return 13
  var tuck_hi = tuck_parseInt("9223372036854775807")
  if not tuck_hi.ok:
    if true:
      return 14
  if (tuck_hi.value != tuck_i64Max()):
    if true:
      return 15
  var tuck_over = tuck_parseInt("9223372036854775808")
  if tuck_over.ok:
    if true:
      return 16
  return tuck_checkParseBad()

proc tuck_checkParseBad*(): int =
  var tuck_empty = tuck_parseInt("")
  if tuck_empty.ok:
    if true:
      return 17
  var tuck_lone = tuck_parseInt("-")
  if tuck_lone.ok:
    if true:
      return 18
  var tuck_trailing = tuck_parseInt("12x")
  if tuck_trailing.ok:
    if true:
      return 19
  var tuck_letters = tuck_parseInt("x")
  if tuck_letters.ok:
    if true:
      return 20
  return 0

proc tuck_main*(): int =
  return tuck_checkNarrow()


when isMainModule:
  quit(tuck_main())
