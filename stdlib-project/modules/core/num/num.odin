#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import bits "./mod_bits"

tuck_ByteOrder :: enum { Big, Little }

tuck_i64Max :: proc () -> i64 {
  return i64(9223372036854775807)
}

tuck_i64Min :: proc () -> i64 {
  return ((i64(0) - tuck_i64Max()) - i64(1))
}

tuck_tryAdd :: proc (a: i64, b: i64) -> rt.TuckResult(i64) {
  if ((b > 0) && (a > (tuck_i64Max() - b))) {
      return rt.tnone(i64)
  }
  if ((b < 0) && (a < (tuck_i64Min() - b))) {
      return rt.tnone(i64)
  }
  return rt.tok((a + b))
}

tuck_trySub :: proc (a: i64, b: i64) -> rt.TuckResult(i64) {
  if ((b < 0) && (a > (tuck_i64Max() + b))) {
      return rt.tnone(i64)
  }
  if ((b > 0) && (a < (tuck_i64Min() + b))) {
      return rt.tnone(i64)
  }
  return rt.tok((a - b))
}

tuck_mulFits :: proc (a: i64, b: i64) -> bool {
  if (a > 0) {
      if (b > 0) {
          return (a <= (tuck_i64Max() / b))
      }
      return (b >= (tuck_i64Min() / a))
  }
  if (b > 0) {
      return (a >= (tuck_i64Min() / b))
  }
  return (a >= (tuck_i64Max() / b))
}

tuck_tryMul :: proc (a: i64, b: i64) -> rt.TuckResult(i64) {
  if ((a == 0) || (b == 0)) {
      return rt.tok(i64(0))
  }
  if !tuck_mulFits(a, b) {
      return rt.tnone(i64)
  }
  return rt.tok((a * b))
}

tuck_tryDiv :: proc (a: i64, b: i64) -> rt.TuckResult(i64) {
  if (b == 0) {
      return rt.tnone(i64)
  }
  if ((a == tuck_i64Min()) && (b == (0 - 1))) {
      return rt.tnone(i64)
  }
  return rt.tok((a / b))
}

tuck_bitMask :: proc (at: int) -> u64 {
  return bits.shiftLeft(u64(1), at)
}

tuck_hasBit :: proc (x: u64, at: int) -> bool {
  return (bits.bitAnd(x, tuck_bitMask(at)) != 0)
}

tuck_withBit :: proc (x: u64, at: int) -> u64 {
  return bits.bitOr(x, tuck_bitMask(at))
}

tuck_withoutBit :: proc (x: u64, at: int) -> u64 {
  return bits.bitAnd(x, bits.bitNot(tuck_bitMask(at)))
}

tuck_flipBit :: proc (x: u64, at: int) -> u64 {
  return bits.bitXor(x, tuck_bitMask(at))
}

tuck_countBits :: proc (x: u64) -> int {
  tuck_n := 0
  for tuck_i in (0 ..= 63) {
      if tuck_hasBit(x, tuck_i) {
          tuck_n = (tuck_n + 1)
      }
  }
  return tuck_n
}

tuck_lowestSetBit :: proc (x: u64) -> rt.TuckResult(int) {
  for tuck_i in (0 ..= 63) {
      if tuck_hasBit(x, tuck_i) {
          return rt.tok(tuck_i)
      }
  }
  return rt.tnone(int)
}

tuck_highestSetBit :: proc (x: u64) -> rt.TuckResult(int) {
  tuck_best := (0 - 1)
  for tuck_i in (0 ..= 63) {
      if tuck_hasBit(x, tuck_i) {
          tuck_best = tuck_i
      }
  }
  if (tuck_best < 0) {
      return rt.tnone(int)
  }
  return rt.tok(tuck_best)
}

tuck_onlyBit :: proc (x: u64) -> rt.TuckResult(int) {
  if (tuck_countBits(x) != 1) {
      return rt.tnone(int)
  }
  for tuck_i in (0 ..= 63) {
      if tuck_hasBit(x, tuck_i) {
          return rt.tok(tuck_i)
      }
  }
  return rt.tnone(int)
}

tuck_setBits :: proc (x: u64) -> [dynamic]int {
  tuck_acc: [dynamic]int = [dynamic]int{}
  for tuck_i in (0 ..= 63) {
      if tuck_hasBit(x, tuck_i) {
          append(&tuck_acc, tuck_i)
      }
  }
  return tuck_acc
}

tuck_shiftFor :: proc (order: tuck_ByteOrder, index: int) -> int {
  switch (order)
  {
  case tuck_ByteOrder.Big: return (56 - (index * 8));
  case tuck_ByteOrder.Little: return (index * 8);
  }
  return {}
}

tuck_byteAt :: proc (value: u64, shift: int) -> u8 {
  tuck_moved := bits.shiftRight(value, shift)
  return u8(bits.bitAnd(tuck_moved, u64(255)))
}

tuck_toBytes :: proc (value: u64, order: tuck_ByteOrder) -> [dynamic]u8 {
  tuck_acc: [dynamic]u8 = [dynamic]u8{}
  for tuck_i in (0 ..= 7) {
      tuck_shift := tuck_shiftFor(order, tuck_i)
      append(&tuck_acc, tuck_byteAt(value, tuck_shift))
  }
  return tuck_acc
}

tuck_fromBytes :: proc (bytes: [dynamic]u8, order: tuck_ByteOrder) -> rt.TuckResult(u64) {
  if (len(bytes) != 8) {
      return rt.tnone(u64)
  }
  tuck_acc: u64 = u64(0)
  for tuck_i in (0 ..= 7) {
      tuck_octet := u64(rt.tuckAt(bytes, tuck_i))
      tuck_shift := tuck_shiftFor(order, tuck_i)
      tuck_acc = bits.bitOr(tuck_acc, bits.shiftLeft(tuck_octet, tuck_shift))
  }
  return rt.tok(tuck_acc)
}

tuck_checkArith :: proc () -> int {
  tuck_over := tuck_tryAdd(tuck_i64Max(), i64(1))
  if (tuck_over.status == .Ok) {
      return 1
  }
  tuck_fine := tuck_tryAdd(tuck_i64Max(), (i64(0) - i64(1)))
  if !(tuck_fine.status == .Ok) {
      return 2
  }
  if (tuck_fine.value != (tuck_i64Max() - 1)) {
      return 3
  }
  return tuck_checkArithRest()
}

tuck_checkArithRest :: proc () -> int {
  tuck_under := tuck_trySub(tuck_i64Min(), i64(1))
  if (tuck_under.status == .Ok) {
      return 4
  }
  tuck_big2 := tuck_tryMul(tuck_i64Max(), i64(2))
  if (tuck_big2.status == .Ok) {
      return 5
  }
  tuck_negMin := tuck_tryMul(tuck_i64Min(), (i64(0) - i64(1)))
  if (tuck_negMin.status == .Ok) {
      return 6
  }
  return tuck_checkDiv()
}

tuck_checkDiv :: proc () -> int {
  tuck_prod := tuck_tryMul(i64(3), i64(4))
  if !(tuck_prod.status == .Ok) {
      return 7
  }
  if (tuck_prod.value != 12) {
      return 8
  }
  tuck_byZero := tuck_tryDiv(i64(1), i64(0))
  if (tuck_byZero.status == .Ok) {
      return 9
  }
  tuck_q := tuck_tryDiv(i64(7), i64(2))
  if !(tuck_q.status == .Ok) {
      return 10
  }
  if (tuck_q.value != 3) {
      return 11
  }
  return 0
}

tuck_threeFlags :: proc () -> u64 {
  tuck_flags: u64 = u64(0)
  tuck_flags = tuck_withBit(tuck_flags, 0)
  tuck_flags = tuck_withBit(tuck_flags, 5)
  return tuck_withBit(tuck_flags, 63)
}

tuck_checkBits :: proc () -> int {
  tuck_flags := tuck_threeFlags()
  if (tuck_countBits(tuck_flags) != 3) {
      return 12
  }
  if !tuck_hasBit(tuck_flags, 5) {
      return 13
  }
  if tuck_hasBit(tuck_flags, 4) {
      return 14
  }
  return tuck_checkBitSearch(tuck_flags)
}

tuck_checkBitSearch :: proc (flags: u64) -> int {
  tuck_lo := tuck_lowestSetBit(flags)
  if !(tuck_lo.status == .Ok) {
      return 15
  }
  if (tuck_lo.value != 0) {
      return 16
  }
  tuck_hi := tuck_highestSetBit(flags)
  if !(tuck_hi.status == .Ok) {
      return 17
  }
  if (tuck_hi.value != 63) {
      return 18
  }
  return tuck_checkBitSets(flags)
}

tuck_checkBitSets :: proc (flags: u64) -> int {
  tuck_positions := rt.tuckSeqCopy(tuck_setBits(flags))
  if (len(tuck_positions) != 3) {
      return 19
  }
  tuck_several := tuck_onlyBit(flags)
  if (tuck_several.status == .Ok) {
      return 20
  }
  return tuck_checkOneBit()
}

tuck_checkOneBit :: proc () -> int {
  tuck_one := tuck_withBit(u64(u64(0)), 7)
  tuck_only := tuck_onlyBit(tuck_one)
  if !(tuck_only.status == .Ok) {
      return 21
  }
  if (tuck_only.value != 7) {
      return 22
  }
  return tuck_checkBitUndo(tuck_one)
}

tuck_checkBitUndo :: proc (one: u64) -> int {
  if (tuck_countBits(tuck_withoutBit(one, 7)) != 0) {
      return 23
  }
  if (tuck_countBits(tuck_flipBit(one, 7)) != 0) {
      return 24
  }
  tuck_empty := tuck_lowestSetBit(u64(u64(0)))
  if (tuck_empty.status == .Ok) {
      return 25
  }
  return 0
}

tuck_checkBytes :: proc () -> int {
  tuck_v := u64(258)
  tuck_big := rt.tuckSeqCopy(tuck_toBytes(tuck_v, tuck_ByteOrder.Big))
  if (len(tuck_big) != 8) {
      return 26
  }
  if (rt.tuckAt(tuck_big, 7) != u8(2)) {
      return 27
  }
  tuck_little := rt.tuckSeqCopy(tuck_toBytes(tuck_v, tuck_ByteOrder.Little))
  if (rt.tuckAt(tuck_little, 0) != u8(2)) {
      return 28
  }
  return tuck_checkRoundTrip(tuck_v, tuck_big)
}

tuck_checkRoundTrip :: proc (v: u64, big: [dynamic]u8) -> int {
  tuck_back := tuck_fromBytes(big, tuck_ByteOrder.Big)
  if !(tuck_back.status == .Ok) {
      return 29
  }
  if (tuck_back.value != v) {
      return 30
  }
  tuck_oneByte: [dynamic]u8 = [dynamic]u8{u8(1)}
  tuck_short := tuck_fromBytes(tuck_oneByte, tuck_ByteOrder.Big)
  if (tuck_short.status == .Ok) {
      return 31
  }
  return 0
}

tuck_main :: proc () -> int {
  tuck_arith := tuck_checkArith()
  if (tuck_arith != 0) {
      return tuck_arith
  }
  tuck_bits := tuck_checkBits()
  if (tuck_bits != 0) {
      return tuck_bits
  }
  return tuck_checkBytes()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
