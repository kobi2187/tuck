#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import bits "./mod_bits"
import str "./mod_str"
import seq "./mod_seq"

tuck_fnvOffsetBasis :: proc () -> u64 {
  return u64(14695981039346656037)
}

tuck_fnvPrime :: proc () -> u64 {
  return u64(1099511628211)
}

tuck_fnvStep :: proc (acc: u64, octet: u64) -> u64 {
  tuck_mixed := bits.bitXor(acc, octet)
  return (tuck_mixed * tuck_fnvPrime())
}

tuck_hashBytes :: proc (data: [dynamic]u8) -> u64 {
  tuck_h := tuck_fnvOffsetBasis()
  for tuck_i in (0 ..= (seq.len(data) - 1)) {
      tuck_octet := u64(rt.tuckAt(data, tuck_i))
      tuck_h = tuck_fnvStep(tuck_h, tuck_octet)
  }
  return tuck_h
}

tuck_strBytes :: proc (t: string) -> [dynamic]u8 {
  tuck_out: [dynamic]u8 = [dynamic]u8{}
  for tuck_i in (0 ..= (str.byteCount(t) - 1)) {
      tuck_b := str.byteAt(t, tuck_i)
      append(&tuck_out, tuck_b)
  }
  return tuck_out
}

tuck_hashStr :: proc (data: string) -> u64 {
  tuck_bytes := rt.tuckSeqCopy(tuck_strBytes(data))
  return tuck_hashBytes(tuck_bytes)
}

tuck_u64Bytes :: proc (x: u64) -> [dynamic]u8 {
  tuck_out: [dynamic]u8 = [dynamic]u8{}
  tuck_i := 0
  for (tuck_i < 8) {
      tuck_shifted := bits.shiftRight(x, (tuck_i * 8))
      tuck_octet := bits.bitAnd(tuck_shifted, u64(255))
      tuck_b := u8(tuck_octet)
      append(&tuck_out, tuck_b)
      tuck_i = (tuck_i + 1)
  }
  return tuck_out
}

tuck_hashU64 :: proc (x: u64) -> u64 {
  tuck_bytes := rt.tuckSeqCopy(tuck_u64Bytes(x))
  return tuck_hashBytes(tuck_bytes)
}

tuck_combine :: proc (a: u64, b: u64) -> u64 {
  return tuck_fnvStep(a, b)
}

tuck_checkHashBytes :: proc () -> int {
  tuck_empty: [dynamic]u8 = [dynamic]u8{}
  if (tuck_hashBytes(tuck_empty) != tuck_fnvOffsetBasis()) {
      return 5
  }
  return 0
}

tuck_checkHashU64 :: proc () -> int {
  if (tuck_hashU64(u64(0)) != tuck_hashU64(u64(0))) {
      return 10
  }
  tuck_a := tuck_hashU64(u64(1))
  tuck_b := tuck_hashU64(u64(2))
  if (tuck_a == tuck_b) {
      return 11
  }
  if (tuck_a != tuck_hashU64(u64(1))) {
      return 12
  }
  if (tuck_hashU64(u64(1)) == tuck_hashU64(u64(256))) {
      return 13
  }
  return 0
}

tuck_main :: proc () -> int {
  if (tuck_hashStr("") != tuck_fnvOffsetBasis()) {
      return 1
  }
  tuck_a := tuck_hashStr("hello")
  tuck_b := tuck_hashStr("world")
  if (tuck_a == tuck_b) {
      return 2
  }
  if (tuck_a != tuck_hashStr("hello")) {
      return 3
  }
  if (tuck_hashStr("ab") == tuck_hashStr("ba")) {
      return 4
  }
  tuck_bytes := tuck_checkHashBytes()
  if (tuck_bytes != 0) {
      return tuck_bytes
  }
  return tuck_checkHashU64()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
