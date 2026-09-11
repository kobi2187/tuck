{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import bits
import seq as tuck_mod_seq

proc tuck_i64Max*(): int64
proc tuck_i64Min*(): int64
proc tuck_tryAdd*(a: int64, b: int64): TuckResult[int64]
proc tuck_trySub*(a: int64, b: int64): TuckResult[int64]
proc tuck_mulFits*(a: int64, b: int64): bool
proc tuck_tryMul*(a: int64, b: int64): TuckResult[int64]
proc tuck_tryDiv*(a: int64, b: int64): TuckResult[int64]
proc tuck_bitMask*(at: int): uint64
proc tuck_hasBit*(x: uint64, at: int): bool
proc tuck_withBit*(x: uint64, at: int): uint64
proc tuck_withoutBit*(x: uint64, at: int): uint64
proc tuck_flipBit*(x: uint64, at: int): uint64
proc tuck_countBits*(x: uint64): int
proc tuck_lowestSetBit*(x: uint64): TuckResult[int]
proc tuck_highestSetBit*(x: uint64): TuckResult[int]
proc tuck_onlyBit*(x: uint64): TuckResult[int]
proc tuck_setBits*(x: uint64): seq[int]
proc tuck_shiftFor*(order: tuck_ByteOrder, index: int): int
proc tuck_byteAt*(value: uint64, shift: int): uint8
proc tuck_toBytes*(value: uint64, order: tuck_ByteOrder): seq[uint8]
proc tuck_fromBytes*(bytes: seq[uint8], order: tuck_ByteOrder): TuckResult[uint64]
proc tuck_checkArith*(): int
proc tuck_checkArithRest*(): int
proc tuck_checkDiv*(): int
proc tuck_threeFlags*(): uint64
proc tuck_checkBits*(): int
proc tuck_checkBitSearch*(flags: uint64): int
proc tuck_checkBitSets*(flags: uint64): int
proc tuck_checkOneBit*(): int
proc tuck_checkBitUndo*(one: uint64): int
proc tuck_checkBytes*(): int
proc tuck_checkRoundTrip*(v: uint64, big: sink seq[uint8]): int
proc tuck_main*(): int

type tuck_ByteOrder* = enum Big, Little

proc tuck_i64Max*(): int64 =
  return 9223372036854775807'i64

proc tuck_i64Min*(): int64 =
  return ((0'i64 - tuck_i64Max()) - 1'i64)

proc tuck_tryAdd*(a: int64, b: int64): TuckResult[int64] =
  if ((b > 0) and (a > (tuck_i64Max() - b))):
    if true:
      return tnone[int64]()
  if ((b < 0) and (a < (tuck_i64Min() - b))):
    if true:
      return tnone[int64]()
  return tok((a + b))

proc tuck_trySub*(a: int64, b: int64): TuckResult[int64] =
  if ((b < 0) and (a > (tuck_i64Max() + b))):
    if true:
      return tnone[int64]()
  if ((b > 0) and (a < (tuck_i64Min() + b))):
    if true:
      return tnone[int64]()
  return tok((a - b))

proc tuck_mulFits*(a: int64, b: int64): bool =
  if (a > 0):
    if true:
      if (b > 0):
        if true:
          return (a <= (tuck_i64Max() div b))
      return (b >= (tuck_i64Min() div a))
  if (b > 0):
    if true:
      return (a >= (tuck_i64Min() div b))
  return (a >= (tuck_i64Max() div b))

proc tuck_tryMul*(a: int64, b: int64): TuckResult[int64] =
  if ((a == 0) or (b == 0)):
    if true:
      return tok(0'i64)
  if not tuck_mulFits(a, b):
    if true:
      return tnone[int64]()
  return tok((a * b))

proc tuck_tryDiv*(a: int64, b: int64): TuckResult[int64] =
  if (b == 0):
    if true:
      return tnone[int64]()
  if ((a == tuck_i64Min()) and (b == (0 - 1))):
    if true:
      return tnone[int64]()
  return tok((a div b))

proc tuck_bitMask*(at: int): uint64 =
  return tuck_rt.shiftLeft(1'u64, at)

proc tuck_hasBit*(x: uint64, at: int): bool =
  var tuck_mask = tuck_bitMask(at)
  return (tuck_rt.bitAnd(x, tuck_mask) != 0)

proc tuck_withBit*(x: uint64, at: int): uint64 =
  var tuck_mask = tuck_bitMask(at)
  return tuck_rt.bitOr(x, tuck_mask)

proc tuck_withoutBit*(x: uint64, at: int): uint64 =
  var tuck_mask = tuck_bitMask(at)
  var tuck_keep = tuck_rt.bitNot(tuck_mask)
  return tuck_rt.bitAnd(x, tuck_keep)

proc tuck_flipBit*(x: uint64, at: int): uint64 =
  var tuck_mask = tuck_bitMask(at)
  return tuck_rt.bitXor(x, tuck_mask)

proc tuck_countBits*(x: uint64): int =
  var tuck_n = 0
  for tuck_i in (0 .. 63):
    if true:
      if tuck_hasBit(x, tuck_i):
        if true:
          tuck_n = (tuck_n + 1)
  return tuck_n

proc tuck_lowestSetBit*(x: uint64): TuckResult[int] =
  for tuck_i in (0 .. 63):
    if true:
      if tuck_hasBit(x, tuck_i):
        if true:
          return tok(tuck_i)
  return tnone[int]()

proc tuck_highestSetBit*(x: uint64): TuckResult[int] =
  var tuck_best = (0 - 1)
  for tuck_i in (0 .. 63):
    if true:
      if tuck_hasBit(x, tuck_i):
        if true:
          tuck_best = tuck_i
  if (tuck_best < 0):
    if true:
      return tnone[int]()
  return tok(tuck_best)

proc tuck_onlyBit*(x: uint64): TuckResult[int] =
  if (tuck_countBits(x) != 1):
    if true:
      return tnone[int]()
  for tuck_i in (0 .. 63):
    if true:
      if tuck_hasBit(x, tuck_i):
        if true:
          return tok(tuck_i)
  return tnone[int]()

proc tuck_setBits*(x: uint64): seq[int] =
  var tuck_acc: seq[int] = @[]
  for tuck_i in (0 .. 63):
    if true:
      if tuck_hasBit(x, tuck_i):
        if true:
          tuck_acc.add(tuck_i)
  return tuck_acc

proc tuck_shiftFor*(order: tuck_ByteOrder, index: int): int =
  (case order
  of Big:
    return (56 - (index * 8))
  of Little:
    return (index * 8))

proc tuck_byteAt*(value: uint64, shift: int): uint8 =
  var tuck_moved = tuck_rt.shiftRight(value, shift)
  var tuck_low = tuck_rt.bitAnd(tuck_moved, 255'u64)
  return uint8(tuck_low)

proc tuck_toBytes*(value: uint64, order: tuck_ByteOrder): seq[uint8] =
  var tuck_acc: seq[uint8] = @[]
  for tuck_i in (0 .. 7):
    if true:
      var tuck_shift = tuck_shiftFor(order, tuck_i)
      var tuck_b = tuck_byteAt(value, tuck_shift)
      tuck_acc.add(tuck_b)
  return tuck_acc

proc tuck_fromBytes*(bytes: seq[uint8], order: tuck_ByteOrder): TuckResult[uint64] =
  if (bytes.len != 8):
    if true:
      return tnone[uint64]()
  var tuck_acc: uint64 = 0'u64
  for tuck_i in (0 .. 7):
    if true:
      var tuck_octet = uint64(tuck_rt.tuckAt(bytes, tuck_i))
      var tuck_shift = tuck_shiftFor(order, tuck_i)
      var tuck_placed = tuck_rt.shiftLeft(tuck_octet, tuck_shift)
      tuck_acc = tuck_rt.bitOr(tuck_acc, tuck_placed)
  return tok(tuck_acc)

proc tuck_checkArith*(): int =
  var tuck_over = tuck_tryAdd(tuck_i64Max(), 1'i64)
  if tuck_over.ok:
    if true:
      return 1
  var tuck_fine = tuck_tryAdd(tuck_i64Max(), (0'i64 - 1'i64))
  if not tuck_fine.ok:
    if true:
      return 2
  if (tuck_fine.value != (tuck_i64Max() - 1)):
    if true:
      return 3
  return tuck_checkArithRest()

proc tuck_checkArithRest*(): int =
  var tuck_under = tuck_trySub(tuck_i64Min(), 1'i64)
  if tuck_under.ok:
    if true:
      return 4
  var tuck_big2 = tuck_tryMul(tuck_i64Max(), 2'i64)
  if tuck_big2.ok:
    if true:
      return 5
  var tuck_negMin = tuck_tryMul(tuck_i64Min(), (0'i64 - 1'i64))
  if tuck_negMin.ok:
    if true:
      return 6
  return tuck_checkDiv()

proc tuck_checkDiv*(): int =
  var tuck_prod = tuck_tryMul(3'i64, 4'i64)
  if not tuck_prod.ok:
    if true:
      return 7
  if (tuck_prod.value != 12):
    if true:
      return 8
  var tuck_byZero = tuck_tryDiv(1'i64, 0'i64)
  if tuck_byZero.ok:
    if true:
      return 9
  var tuck_q = tuck_tryDiv(7'i64, 2'i64)
  if not tuck_q.ok:
    if true:
      return 10
  if (tuck_q.value != 3):
    if true:
      return 11
  return 0

proc tuck_threeFlags*(): uint64 =
  var tuck_flags: uint64 = 0'u64
  tuck_flags = tuck_withBit(tuck_flags, 0)
  tuck_flags = tuck_withBit(tuck_flags, 5)
  return tuck_withBit(tuck_flags, 63)

proc tuck_checkBits*(): int =
  var tuck_flags = tuck_threeFlags()
  if (tuck_countBits(tuck_flags) != 3):
    if true:
      return 12
  if not tuck_hasBit(tuck_flags, 5):
    if true:
      return 13
  if tuck_hasBit(tuck_flags, 4):
    if true:
      return 14
  return tuck_checkBitSearch(tuck_flags)

proc tuck_checkBitSearch*(flags: uint64): int =
  var tuck_lo = tuck_lowestSetBit(flags)
  if not tuck_lo.ok:
    if true:
      return 15
  if (tuck_lo.value != 0):
    if true:
      return 16
  var tuck_hi = tuck_highestSetBit(flags)
  if not tuck_hi.ok:
    if true:
      return 17
  if (tuck_hi.value != 63):
    if true:
      return 18
  return tuck_checkBitSets(flags)

proc tuck_checkBitSets*(flags: uint64): int =
  var tuck_positions = tuck_setBits(flags)
  if (tuck_positions.len != 3):
    if true:
      return 19
  var tuck_several = tuck_onlyBit(flags)
  if tuck_several.ok:
    if true:
      return 20
  return tuck_checkOneBit()

proc tuck_checkOneBit*(): int =
  var tuck_zero = uint64(0)
  var tuck_one = tuck_withBit(tuck_zero, 7)
  var tuck_only = tuck_onlyBit(tuck_one)
  if not tuck_only.ok:
    if true:
      return 21
  if (tuck_only.value != 7):
    if true:
      return 22
  return tuck_checkBitUndo(tuck_one)

proc tuck_checkBitUndo*(one: uint64): int =
  var tuck_cleared = tuck_withoutBit(one, 7)
  if (tuck_countBits(tuck_cleared) != 0):
    if true:
      return 23
  var tuck_flipped = tuck_flipBit(one, 7)
  if (tuck_countBits(tuck_flipped) != 0):
    if true:
      return 24
  var tuck_none0 = uint64(0)
  var tuck_empty = tuck_lowestSetBit(tuck_none0)
  if tuck_empty.ok:
    if true:
      return 25
  return 0

proc tuck_checkBytes*(): int =
  var tuck_v = uint64(258)
  var tuck_big = tuck_toBytes(tuck_v, tuck_ByteOrder.Big)
  if (tuck_big.len != 8):
    if true:
      return 26
  if (tuck_rt.tuckAt(tuck_big, 7) != uint8(2)):
    if true:
      return 27
  var tuck_little = tuck_toBytes(tuck_v, tuck_ByteOrder.Little)
  if (tuck_rt.tuckAt(tuck_little, 0) != uint8(2)):
    if true:
      return 28
  return tuck_checkRoundTrip(tuck_v, tuck_big)

proc tuck_checkRoundTrip*(v: uint64, big: sink seq[uint8]): int =
  var tuck_back = tuck_fromBytes(big, tuck_ByteOrder.Big)
  if not tuck_back.ok:
    if true:
      return 29
  if (tuck_back.value != v):
    if true:
      return 30
  var tuck_oneByte: seq[uint8] = @[uint8(1)]
  var tuck_short = tuck_fromBytes(tuck_oneByte, tuck_ByteOrder.Big)
  if tuck_short.ok:
    if true:
      return 31
  return 0

proc tuck_main*(): int =
  var tuck_arith = tuck_checkArith()
  if (tuck_arith != 0):
    if true:
      return tuck_arith
  var tuck_bits = tuck_checkBits()
  if (tuck_bits != 0):
    if true:
      return tuck_bits
  return tuck_checkBytes()


when isMainModule:
  quit(tuck_main())
