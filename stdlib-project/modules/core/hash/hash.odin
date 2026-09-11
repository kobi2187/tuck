#+feature dynamic-literals
package main

import "core:os"
import bits "./mod_bits"
import str "./mod_str"

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

tuck_hashStr :: proc (data: string) -> u64 {
  tuck_h := tuck_fnvOffsetBasis()
  for tuck_i in (0 ..= (str.byteCount(data) - 1)) {
      tuck_b := str.byteAt(data, tuck_i)
      tuck_octet := u64(tuck_b)
      tuck_h = tuck_fnvStep(tuck_h, tuck_octet)
  }
  return tuck_h
}

tuck_combine :: proc (a: u64, b: u64) -> u64 {
  return tuck_fnvStep(a, b)
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
  return 0
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
