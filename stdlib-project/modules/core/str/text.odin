#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import str "./mod_str"
import seq "./mod_seq"

tuck_Rune :: u32

tuck_Char :: u8

tuck_isEmpty :: proc (t: string) -> bool {
  return (str.byteCount(t) == 0)
}

tuck_charAtByte :: proc (t: string, index: int) -> rt.TuckResult(tuck_Char) {
  if ((index < 0) || (index >= str.byteCount(t))) {
      return rt.tnone(tuck_Char)
  }
  return rt.tok(str.byteAt(t, index))
}

tuck_runeWidth :: proc (lead: u8) -> int {
  tuck_b := int(lead)
  if (tuck_b < 128) {
      return 1
  }
  if (tuck_b < 224) {
      return 2
  }
  if (tuck_b < 240) {
      return 3
  }
  return 4
}

tuck_continuationBits :: proc (t: string, index: int) -> int {
  if (index >= str.byteCount(t)) {
      return 0
  }
  tuck_b := str.byteAt(t, index)
  return (int(tuck_b) % 64)
}

tuck_leadBits :: proc (lead: u8, width: int) -> int {
  tuck_b := int(lead)
  if (width == 1) {
      return tuck_b
  }
  if (width == 2) {
      return (tuck_b % 32)
  }
  if (width == 3) {
      return (tuck_b % 16)
  }
  return (tuck_b % 8)
}

tuck_runeAt :: proc (t: string, at: int) -> rt.TuckResult(tuck_Rune) {
  if ((at < 0) || (at >= str.byteCount(t))) {
      return rt.tnone(tuck_Rune)
  }
  tuck_lead := str.byteAt(t, at)
  tuck_width := tuck_runeWidth(tuck_lead)
  tuck_acc := tuck_leadBits(tuck_lead, tuck_width)
  for tuck_i in (1 ..= (tuck_width - 1)) {
      tuck_acc = ((tuck_acc * 64) + tuck_continuationBits(t, (at + tuck_i)))
  }
  return rt.tok(u32(tuck_acc))
}

tuck_nextRune :: proc (t: string, at: int) -> int {
  tuck_lead := str.byteAt(t, at)
  return (at + tuck_runeWidth(tuck_lead))
}

tuck_runeCount :: proc (t: string) -> int {
  tuck_n := 0
  tuckfn_at := 0
  for (tuckfn_at < str.byteCount(t)) {
      tuck_n = (tuck_n + 1)
      tuckfn_at = tuck_nextRune(t, tuckfn_at)
  }
  return tuck_n
}

tuck_noRunes :: proc () -> [dynamic]tuck_Rune {
  return [dynamic]tuck_Rune{}
}

tuck_runes :: proc (t: string) -> [dynamic]tuck_Rune {
  tuck_acc := rt.tuckSeqCopy(tuck_noRunes())
  tuckfn_at := 0
  for (tuckfn_at < str.byteCount(t)) {
      tuck_r := tuck_runeAt(t, tuckfn_at)
      if (tuck_r.status == .Ok) {
          append(&tuck_acc, tuck_r.value)
      }
      tuckfn_at = tuck_nextRune(t, tuckfn_at)
  }
  return tuck_acc
}

tuck_noBytes :: proc () -> [dynamic]u8 {
  return [dynamic]u8{}
}

tuck_encodeRune :: proc (r: tuck_Rune, into: [dynamic]u8) -> [dynamic]u8 {
  tuck_v := int(r)
  tuck_out := rt.tuckSeqCopy(into)
  if (tuck_v < 128) {
      tuck_b := u8(tuck_v)
      return seq.push(tuck_out, tuck_b)
  }
  if (tuck_v < 2048) {
      tuck_lead := u8((192 + (tuck_v / 64)))
      append(&tuck_out, tuck_lead)
      tuck_tail := u8((128 + (tuck_v % 64)))
      return seq.push(tuck_out, tuck_tail)
  }
  if (tuck_v < 65536) {
      tuck_lead := u8((224 + (tuck_v / 4096)))
      append(&tuck_out, tuck_lead)
      tuck_mid := u8((128 + ((tuck_v / 64) % 64)))
      append(&tuck_out, tuck_mid)
      tuck_tail := u8((128 + (tuck_v % 64)))
      return seq.push(tuck_out, tuck_tail)
  }
  tuck_lead := u8((240 + (tuck_v / 262144)))
  append(&tuck_out, tuck_lead)
  tuck_hi := u8((128 + ((tuck_v / 4096) % 64)))
  append(&tuck_out, tuck_hi)
  tuck_mid := u8((128 + ((tuck_v / 64) % 64)))
  append(&tuck_out, tuck_mid)
  tuck_tail := u8((128 + (tuck_v % 64)))
  return seq.push(tuck_out, tuck_tail)
}

tuck_fromRunes :: proc (rs: [dynamic]tuck_Rune) -> string {
  tuck_bytes := rt.tuckSeqCopy(tuck_noBytes())
  for tuck_i in (0 ..= (seq.count(rs) - 1)) {
      tuck_bytes = rt.tuckSeqCopy(tuck_encodeRune(rt.tuckAt(rs, tuck_i), tuck_bytes))
  }
  return str.fromBytes(tuck_bytes)
}

tuck_matchesAt :: proc (t: string, at: int, what: string) -> bool {
  tuck_n := str.byteCount(what)
  if ((at + tuck_n) > str.byteCount(t)) {
      return false
  }
  for tuck_i in (0 ..= (tuck_n - 1)) {
      if (str.byteAt(t, (at + tuck_i)) != str.byteAt(what, tuck_i)) {
          return false
      }
  }
  return true
}

tuck_find :: proc (t: string, what: string) -> rt.TuckResult(int) {
  if (str.byteCount(what) == 0) {
      return rt.tok(0)
  }
  for tuck_i in (0 ..= (str.byteCount(t) - str.byteCount(what))) {
      if tuck_matchesAt(t, tuck_i, what) {
          return rt.tok(tuck_i)
      }
  }
  return rt.tnone(int)
}

tuck_has :: proc (t: string, what: string) -> bool {
  tuckfn_at := tuck_find(t, what)
  return (tuckfn_at.status == .Ok)
}

tuck_startsWith :: proc (t: string, prefix: string) -> bool {
  return tuck_matchesAt(t, 0, prefix)
}

tuck_endsWith :: proc (t: string, suffix: string) -> bool {
  tuckfn_at := (str.byteCount(t) - str.byteCount(suffix))
  if (tuckfn_at < 0) {
      return false
  }
  return tuck_matchesAt(t, tuckfn_at, suffix)
}

tuck_slice :: proc (t: string, start: int, stop: int) -> rt.TuckResult(string) {
  if ((start < 0) || ((stop > str.byteCount(t)) || (start > stop))) {
      return rt.tnone(string)
  }
  tuck_out := rt.tuckSeqCopy(tuck_noBytes())
  for tuck_i in (start ..= (stop - 1)) {
      tuck_b := str.byteAt(t, tuck_i)
      append(&tuck_out, tuck_b)
  }
  return rt.tok(str.fromBytes(tuck_out))
}

tuck_noParts :: proc () -> [dynamic]string {
  return [dynamic]string{}
}

tuck_split :: proc (t: string, at: string) -> [dynamic]string {
  tuck_parts := rt.tuckSeqCopy(tuck_noParts())
  if (str.byteCount(at) == 0) {
      return seq.push(tuck_parts, t)
  }
  tuck_start := 0
  tuck_i := 0
  for (tuck_i <= (str.byteCount(t) - str.byteCount(at))) {
      if tuck_matchesAt(t, tuck_i, at) {
          tuck_piece := tuck_slice(t, tuck_start, tuck_i)
          if (tuck_piece.status == .Ok) {
              append(&tuck_parts, tuck_piece.value)
          }
          tuck_i = (tuck_i + str.byteCount(at))
          tuck_start = tuck_i
      } else {
          tuck_i = (tuck_i + 1)
      }
  }
  tuck_n := str.byteCount(t)
  tuck_last := tuck_slice(t, tuck_start, tuck_n)
  if (tuck_last.status == .Ok) {
      append(&tuck_parts, tuck_last.value)
  }
  return tuck_parts
}

tuck_isSpaceByte :: proc (b: u8) -> bool {
  tuck_v := int(b)
  return ((tuck_v == 32) || ((tuck_v == 9) || ((tuck_v == 10) || (tuck_v == 13))))
}

tuck_trimStart :: proc (t: string) -> string {
  tuck_i := 0
  for (tuck_i < str.byteCount(t)) {
      tuck_b := str.byteAt(t, tuck_i)
      if !tuck_isSpaceByte(tuck_b) {
          break
      }
      tuck_i = (tuck_i + 1)
  }
  tuck_n := str.byteCount(t)
  tuck_out := tuck_slice(t, tuck_i, tuck_n)
  if !(tuck_out.status == .Ok) {
      return ""
  }
  return tuck_out.value
}

tuck_trimEnd :: proc (t: string) -> string {
  tuck_n := str.byteCount(t)
  for (tuck_n > 0) {
      tuck_b := str.byteAt(t, (tuck_n - 1))
      if !tuck_isSpaceByte(tuck_b) {
          break
      }
      tuck_n = (tuck_n - 1)
  }
  tuck_out := tuck_slice(t, 0, tuck_n)
  if !(tuck_out.status == .Ok) {
      return ""
  }
  return tuck_out.value
}

tuck_trim :: proc (t: string) -> string {
  tuck_head := tuck_trimStart(t)
  return tuck_trimEnd(tuck_head)
}

tuck_lowerByte :: proc (b: u8) -> u8 {
  tuck_v := int(b)
  if ((tuck_v >= 65) && (tuck_v <= 90)) {
      return u8((tuck_v + 32))
  }
  return b
}

tuck_upperByte :: proc (b: u8) -> u8 {
  tuck_v := int(b)
  if ((tuck_v >= 97) && (tuck_v <= 122)) {
      return u8((tuck_v - 32))
  }
  return b
}

tuck_toLowerAscii :: proc (t: string) -> string {
  tuck_out := rt.tuckSeqCopy(tuck_noBytes())
  for tuck_i in (0 ..= (str.byteCount(t) - 1)) {
      tuck_b := str.byteAt(t, tuck_i)
      tuck_low := tuck_lowerByte(tuck_b)
      append(&tuck_out, tuck_low)
  }
  return str.fromBytes(tuck_out)
}

tuck_toUpperAscii :: proc (t: string) -> string {
  tuck_out := rt.tuckSeqCopy(tuck_noBytes())
  for tuck_i in (0 ..= (str.byteCount(t) - 1)) {
      tuck_b := str.byteAt(t, tuck_i)
      tuck_up := tuck_upperByte(tuck_b)
      append(&tuck_out, tuck_up)
  }
  return str.fromBytes(tuck_out)
}

tuck_checkAscii :: proc () -> int {
  if !tuck_isEmpty("") {
      return 1
  }
  if tuck_isEmpty("a") {
      return 2
  }
  tuck_c := tuck_charAtByte("abc", 1)
  if !(tuck_c.status == .Ok) {
      return 3
  }
  if (int(tuck_c.value) != 98) {
      return 4
  }
  tuck_past := tuck_charAtByte("abc", 9)
  if (tuck_past.status == .Ok) {
      return 5
  }
  return tuck_checkSearch()
}

tuck_checkSearch :: proc () -> int {
  tuckfn_at := tuck_find("hello", "ll")
  if !(tuckfn_at.status == .Ok) {
      return 6
  }
  if (tuckfn_at.value != 2) {
      return 7
  }
  tuck_missing := tuck_find("hello", "zz")
  if (tuck_missing.status == .Ok) {
      return 8
  }
  if !tuck_has("hello", "ell") {
      return 9
  }
  if !tuck_startsWith("hello", "he") {
      return 10
  }
  if !tuck_endsWith("hello", "lo") {
      return 11
  }
  if tuck_endsWith("hi", "longer") {
      return 12
  }
  return tuck_checkSliceSplit()
}

tuck_checkSliceSplit :: proc () -> int {
  tuck_s := tuck_slice("hello", 1, 3)
  if !(tuck_s.status == .Ok) {
      return 13
  }
  if (tuck_s.value != "el") {
      return 14
  }
  tuck_bad := tuck_slice("hi", 0, 99)
  if (tuck_bad.status == .Ok) {
      return 15
  }
  tuck_parts := rt.tuckSeqCopy(tuck_split("a,b,c", ","))
  if (seq.count(tuck_parts) != 3) {
      return 16
  }
  if (rt.tuckAt(tuck_parts, 0) != "a") {
      return 17
  }
  if (rt.tuckAt(tuck_parts, 2) != "c") {
      return 18
  }
  return tuck_checkTrimCase()
}

tuck_checkTrimCase :: proc () -> int {
  if (tuck_trim("  hi  ") != "hi") {
      return 19
  }
  if (tuck_trimStart("  hi") != "hi") {
      return 20
  }
  if (tuck_trimEnd("hi  ") != "hi") {
      return 21
  }
  if (tuck_trim("   ") != "") {
      return 22
  }
  if (tuck_toLowerAscii("AbC") != "abc") {
      return 23
  }
  if (tuck_toUpperAscii("AbC") != "ABC") {
      return 24
  }
  return tuck_checkRunes()
}

tuck_checkRunes :: proc () -> int {
  tuck_s := "héllo"
  if (str.byteCount(tuck_s) != 6) {
      return 25
  }
  if (tuck_runeCount(tuck_s) != 5) {
      return 26
  }
  tuck_r := tuck_runeAt(tuck_s, 1)
  if !(tuck_r.status == .Ok) {
      return 27
  }
  if (int(tuck_r.value) != 233) {
      return 28
  }
  tuck_rs := rt.tuckSeqCopy(tuck_runes(tuck_s))
  if (seq.count(tuck_rs) != 5) {
      return 29
  }
  tuck_rs2 := rt.tuckSeqCopy(tuck_runes(tuck_s))
  if (tuck_fromRunes(tuck_rs2) != tuck_s) {
      return 30
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_checkAscii()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
