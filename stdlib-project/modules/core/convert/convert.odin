#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import str "./mod_str"

tuck_i64Max :: proc () -> i64 {
  return i64(9223372036854775807)
}

tuck_i64Min :: proc () -> i64 {
  return ((i64(0) - tuck_i64Max()) - i64(1))
}

tuck_i32Max :: proc () -> i64 {
  return i64(2147483647)
}

tuck_i32Min :: proc () -> i64 {
  return ((i64(0) - tuck_i32Max()) - i64(1))
}

tuck_toNarrow :: proc (x: i64) -> rt.TuckResult(i32) {
  if ((x < tuck_i32Min()) || (x > tuck_i32Max())) {
      return rt.tnone(i32)
  }
  return rt.tok(i32(x))
}

tuck_toNarrowClamped :: proc (x: i64) -> i32 {
  if (x < tuck_i32Min()) {
      return i32(tuck_i32Min())
  }
  if (x > tuck_i32Max()) {
      return i32(tuck_i32Max())
  }
  return i32(x)
}

tuck_toApprox :: proc (x: f64) -> f32 {
  return f32(x)
}

tuck_digitOf :: proc (t: string, index: int) -> rt.TuckResult(int) {
  tuck_raw := str.byteAt(t, index)
  tuck_b := int(tuck_raw)
  if ((tuck_b < 48) || (tuck_b > 57)) {
      return rt.tnone(int)
  }
  return rt.tok((tuck_b - 48))
}

tuck_isSign :: proc (t: string, index: int) -> bool {
  tuck_raw := str.byteAt(t, index)
  tuck_b := int(tuck_raw)
  return ((tuck_b == 43) || (tuck_b == 45))
}

tuck_isNegative :: proc (t: string) -> bool {
  if (str.byteCount(t) == 0) {
      return false
  }
  tuck_lead := str.byteAt(t, 0)
  return (int(tuck_lead) == 45)
}

tuck_parseInt :: proc (t: string) -> rt.TuckResult(i64) {
  tuck_n := str.byteCount(t)
  if (tuck_n == 0) {
      return rt.tnone(i64)
  }
  tuck_start := 0
  if tuck_isSign(t, 0) {
      tuck_start = 1
  }
  if (tuck_start >= tuck_n) {
      return rt.tnone(i64)
  }
  tuck_neg := tuck_isNegative(t)
  return tuck_accumulate(t, tuck_start, tuck_n, tuck_neg)
}

tuck_accumulate :: proc (t: string, start: int, count: int, neg: bool) -> rt.TuckResult(i64) {
  tuck_acc: i64 = i64(0)
  for tuck_i in (start ..= (count - 1)) {
      tuck_d := tuck_digitOf(t, tuck_i)
      if !(tuck_d.status == .Ok) {
          return rt.tnone(i64)
      }
      tuck_step := tuck_addDigit(tuck_acc, tuck_d.value, neg)
      if !(tuck_step.status == .Ok) {
          return rt.tnone(i64)
      }
      tuck_acc = tuck_step.value
  }
  return rt.tok(tuck_acc)
}

tuck_addDigit :: proc (acc: i64, digit: int, neg: bool) -> rt.TuckResult(i64) {
  tuck_d := i64(digit)
  if neg {
      if (acc < ((tuck_i64Min() + tuck_d) / 10)) {
          return rt.tnone(i64)
      }
      return rt.tok(((acc * i64(10)) - tuck_d))
  }
  if (acc > ((tuck_i64Max() - tuck_d) / 10)) {
      return rt.tnone(i64)
  }
  return rt.tok(((acc * i64(10)) + tuck_d))
}

tuck_checkNarrow :: proc () -> int {
  tuck_ok := tuck_toNarrow(i64(1000))
  if !(tuck_ok.status == .Ok) {
      return 1
  }
  if (int(tuck_ok.value) != 1000) {
      return 2
  }
  tuck_past := tuck_toNarrow(i64(3000000000))
  if (tuck_past.status == .Ok) {
      return 3
  }
  tuck_hi := tuck_toNarrowClamped(i64(3000000000))
  if (i64(tuck_hi) != tuck_i32Max()) {
      return 4
  }
  tuck_lo := tuck_toNarrowClamped((i64(0) - i64(3000000000)))
  if (i64(tuck_lo) != tuck_i32Min()) {
      return 5
  }
  return tuck_checkParseOk()
}

tuck_checkParseOk :: proc () -> int {
  tuck_a := tuck_parseInt("123")
  if !(tuck_a.status == .Ok) {
      return 6
  }
  if (tuck_a.value != 123) {
      return 7
  }
  tuck_b := tuck_parseInt("-45")
  if !(tuck_b.status == .Ok) {
      return 8
  }
  if (tuck_b.value != (0 - 45)) {
      return 9
  }
  tuck_c := tuck_parseInt("+7")
  if !(tuck_c.status == .Ok) {
      return 10
  }
  if (tuck_c.value != 7) {
      return 11
  }
  return tuck_checkParseEdges()
}

tuck_checkParseEdges :: proc () -> int {
  tuck_lo := tuck_parseInt("-9223372036854775808")
  if !(tuck_lo.status == .Ok) {
      return 12
  }
  if (tuck_lo.value != tuck_i64Min()) {
      return 13
  }
  tuck_hi := tuck_parseInt("9223372036854775807")
  if !(tuck_hi.status == .Ok) {
      return 14
  }
  if (tuck_hi.value != tuck_i64Max()) {
      return 15
  }
  tuck_over := tuck_parseInt("9223372036854775808")
  if (tuck_over.status == .Ok) {
      return 16
  }
  return tuck_checkParseBad()
}

tuck_checkParseBad :: proc () -> int {
  tuck_empty := tuck_parseInt("")
  if (tuck_empty.status == .Ok) {
      return 17
  }
  tuck_lone := tuck_parseInt("-")
  if (tuck_lone.status == .Ok) {
      return 18
  }
  tuck_trailing := tuck_parseInt("12x")
  if (tuck_trailing.status == .Ok) {
      return 19
  }
  tuck_letters := tuck_parseInt("x")
  if (tuck_letters.status == .Ok) {
      return 20
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_checkNarrow()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
