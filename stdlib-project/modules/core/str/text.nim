{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq
import str

proc tuck_isEmpty*(t: sink string): bool
proc tuck_charAtByte*(t: sink string, index: int): TuckResult[tuck_Char]
proc tuck_runeWidth*(lead: uint8): int
proc tuck_continuationBits*(t: sink string, index: int): int
proc tuck_leadBits*(lead: uint8, width: int): int
proc tuck_runeAt*(t: string, at: int): TuckResult[tuck_Rune]
proc tuck_nextRune*(t: sink string, at: int): int
proc tuck_runeCount*(t: string): int
proc tuck_noRunes*(): seq[tuck_Rune]
proc tuck_runes*(t: string): seq[tuck_Rune]
proc tuck_noBytes*(): seq[uint8]
proc tuck_encodeRune*(r: tuck_Rune, into: sink seq[uint8]): seq[uint8]
proc tuck_fromRunes*(rs: seq[tuck_Rune]): string
proc tuck_matchesAt*(t: string, at: int, what: string): bool
proc tuck_find*(t: string, what: string): TuckResult[int]
proc tuck_has*(t: sink string, what: sink string): bool
proc tuck_startsWith*(t: sink string, prefix: sink string): bool
proc tuck_endsWith*(t: sink string, suffix: sink string): bool
proc tuck_slice*(t: string, start: int, stop: int): TuckResult[string]
proc tuck_noParts*(): seq[string]
proc tuck_split*(t: string, at: string): seq[string]
proc tuck_isSpaceByte*(b: uint8): bool
proc tuck_trimStart*(t: string): string
proc tuck_trimEnd*(t: string): string
proc tuck_trim*(t: sink string): string
proc tuck_lowerByte*(b: uint8): uint8
proc tuck_upperByte*(b: uint8): uint8
proc tuck_toLowerAscii*(t: string): string
proc tuck_toUpperAscii*(t: string): string
proc tuck_checkAscii*(): int
proc tuck_checkSearch*(): int
proc tuck_checkSliceSplit*(): int
proc tuck_checkTrimCase*(): int
proc tuck_checkRunes*(): int
proc tuck_main*(): int

type tuck_Rune* = uint32

type tuck_Char* = uint8

proc tuck_isEmpty*(t: sink string): bool =
  return (tuck_rt.byteCount(t) == 0)

proc tuck_charAtByte*(t: sink string, index: int): TuckResult[tuck_Char] =
  if ((index < 0) or (index >= tuck_rt.byteCount(t))):
    if true:
      return tnone[tuck_Char]()
  return tok(tuck_rt.byteAt(t, index))

proc tuck_runeWidth*(lead: uint8): int =
  var tuck_b = int(lead)
  if (tuck_b < 128):
    if true:
      return 1
  if (tuck_b < 224):
    if true:
      return 2
  if (tuck_b < 240):
    if true:
      return 3
  return 4

proc tuck_continuationBits*(t: sink string, index: int): int =
  if (index >= tuck_rt.byteCount(t)):
    if true:
      return 0
  var tuck_b = tuck_rt.byteAt(t, index)
  return (int(tuck_b) mod 64)

proc tuck_leadBits*(lead: uint8, width: int): int =
  var tuck_b = int(lead)
  if (width == 1):
    if true:
      return tuck_b
  if (width == 2):
    if true:
      return (tuck_b mod 32)
  if (width == 3):
    if true:
      return (tuck_b mod 16)
  return (tuck_b mod 8)

proc tuck_runeAt*(t: string, at: int): TuckResult[tuck_Rune] =
  if ((at < 0) or (at >= tuck_rt.byteCount(t))):
    if true:
      return tnone[tuck_Rune]()
  var tuck_lead = tuck_rt.byteAt(t, at)
  var tuck_width = tuck_runeWidth(tuck_lead)
  var tuck_acc = tuck_leadBits(tuck_lead, tuck_width)
  for tuck_i in (1 .. (tuck_width - 1)):
    if true:
      tuck_acc = ((tuck_acc * 64) + tuck_continuationBits(t, (at + tuck_i)))
  return tok(uint32(tuck_acc))

proc tuck_nextRune*(t: sink string, at: int): int =
  var tuck_lead = tuck_rt.byteAt(t, at)
  return (at + tuck_runeWidth(tuck_lead))

proc tuck_runeCount*(t: string): int =
  var tuck_n = 0
  var tuckfn_at = 0
  while (tuckfn_at < tuck_rt.byteCount(t)):
    if true:
      tuck_n = (tuck_n + 1)
      tuckfn_at = tuck_nextRune(t, tuckfn_at)
  return tuck_n

proc tuck_noRunes*(): seq[tuck_Rune] =
  return @[]

proc tuck_runes*(t: string): seq[tuck_Rune] =
  var tuck_acc = tuck_noRunes()
  var tuckfn_at = 0
  while (tuckfn_at < tuck_rt.byteCount(t)):
    if true:
      var tuck_r = tuck_runeAt(t, tuckfn_at)
      if tuck_r.ok:
        if true:
          tuck_acc.add(tuck_r.value)
      tuckfn_at = tuck_nextRune(t, tuckfn_at)
  return tuck_acc

proc tuck_noBytes*(): seq[uint8] =
  return @[]

proc tuck_encodeRune*(r: tuck_Rune, into: sink seq[uint8]): seq[uint8] =
  var tuck_v = int(r)
  var tuck_out = into
  if (tuck_v < 128):
    if true:
      var tuck_b = uint8(tuck_v)
      return tuck_rt.push(tuck_out, tuck_b)
  if (tuck_v < 2048):
    if true:
      var tuck_lead = uint8((192 + (tuck_v div 64)))
      tuck_out.add(tuck_lead)
      var tuck_tail = uint8((128 + (tuck_v mod 64)))
      return tuck_rt.push(tuck_out, tuck_tail)
  if (tuck_v < 65536):
    if true:
      var tuck_lead = uint8((224 + (tuck_v div 4096)))
      tuck_out.add(tuck_lead)
      var tuck_mid = uint8((128 + ((tuck_v div 64) mod 64)))
      tuck_out.add(tuck_mid)
      var tuck_tail = uint8((128 + (tuck_v mod 64)))
      return tuck_rt.push(tuck_out, tuck_tail)
  var tuck_lead = uint8((240 + (tuck_v div 262144)))
  tuck_out.add(tuck_lead)
  var tuck_hi = uint8((128 + ((tuck_v div 4096) mod 64)))
  tuck_out.add(tuck_hi)
  var tuck_mid = uint8((128 + ((tuck_v div 64) mod 64)))
  tuck_out.add(tuck_mid)
  var tuck_tail = uint8((128 + (tuck_v mod 64)))
  return tuck_rt.push(tuck_out, tuck_tail)

proc tuck_fromRunes*(rs: seq[tuck_Rune]): string =
  var tuck_bytes = tuck_noBytes()
  for tuck_i in (0 .. (tuck_rt.count(rs) - 1)):
    if true:
      tuck_bytes = tuck_encodeRune(tuck_rt.tuckAt(rs, tuck_i), tuck_bytes)
  return tuck_rt.fromBytes(tuck_bytes)

proc tuck_matchesAt*(t: string, at: int, what: string): bool =
  var tuck_n = tuck_rt.byteCount(what)
  if ((at + tuck_n) > tuck_rt.byteCount(t)):
    if true:
      return false
  for tuck_i in (0 .. (tuck_n - 1)):
    if true:
      if (tuck_rt.byteAt(t, (at + tuck_i)) != tuck_rt.byteAt(what, tuck_i)):
        if true:
          return false
  return true

proc tuck_find*(t: string, what: string): TuckResult[int] =
  if (tuck_rt.byteCount(what) == 0):
    if true:
      return tok(0)
  for tuck_i in (0 .. (tuck_rt.byteCount(t) - tuck_rt.byteCount(what))):
    if true:
      if tuck_matchesAt(t, tuck_i, what):
        if true:
          return tok(tuck_i)
  return tnone[int]()

proc tuck_has*(t: sink string, what: sink string): bool =
  var tuckfn_at = tuck_find(t, what)
  return tuckfn_at.ok

proc tuck_startsWith*(t: sink string, prefix: sink string): bool =
  return tuck_matchesAt(t, 0, prefix)

proc tuck_endsWith*(t: sink string, suffix: sink string): bool =
  var tuckfn_at = (tuck_rt.byteCount(t) - tuck_rt.byteCount(suffix))
  if (tuckfn_at < 0):
    if true:
      return false
  return tuck_matchesAt(t, tuckfn_at, suffix)

proc tuck_slice*(t: string, start: int, stop: int): TuckResult[string] =
  if ((start < 0) or ((stop > tuck_rt.byteCount(t)) or (start > stop))):
    if true:
      return tnone[string]()
  var tuck_out = tuck_noBytes()
  for tuck_i in (start .. (stop - 1)):
    if true:
      var tuck_b = tuck_rt.byteAt(t, tuck_i)
      tuck_out.add(tuck_b)
  return tok(tuck_rt.fromBytes(tuck_out))

proc tuck_noParts*(): seq[string] =
  return @[]

proc tuck_split*(t: string, at: string): seq[string] =
  var tuck_parts = tuck_noParts()
  if (tuck_rt.byteCount(at) == 0):
    if true:
      return tuck_rt.push(tuck_parts, t)
  var tuck_start = 0
  var tuck_i = 0
  while (tuck_i <= (tuck_rt.byteCount(t) - tuck_rt.byteCount(at))):
    if true:
      if tuck_matchesAt(t, tuck_i, at):
        if true:
          var tuck_piece = tuck_slice(t, tuck_start, tuck_i)
          if tuck_piece.ok:
            if true:
              tuck_parts.add(tuck_piece.value)
          tuck_i = (tuck_i + tuck_rt.byteCount(at))
          tuck_start = tuck_i
      else:
        if true:
          tuck_i = (tuck_i + 1)
  var tuck_n = tuck_rt.byteCount(t)
  var tuck_last = tuck_slice(t, tuck_start, tuck_n)
  if tuck_last.ok:
    if true:
      tuck_parts.add(tuck_last.value)
  return tuck_parts

proc tuck_isSpaceByte*(b: uint8): bool =
  var tuck_v = int(b)
  return ((tuck_v == 32) or ((tuck_v == 9) or ((tuck_v == 10) or (tuck_v == 13))))

proc tuck_trimStart*(t: string): string =
  var tuck_i = 0
  while (tuck_i < tuck_rt.byteCount(t)):
    if true:
      var tuck_b = tuck_rt.byteAt(t, tuck_i)
      if not tuck_isSpaceByte(tuck_b):
        if true:
          break
      tuck_i = (tuck_i + 1)
  var tuck_n = tuck_rt.byteCount(t)
  var tuck_out = tuck_slice(t, tuck_i, tuck_n)
  if not tuck_out.ok:
    if true:
      return ""
  return tuck_out.value

proc tuck_trimEnd*(t: string): string =
  var tuck_n = tuck_rt.byteCount(t)
  while (tuck_n > 0):
    if true:
      var tuck_b = tuck_rt.byteAt(t, (tuck_n - 1))
      if not tuck_isSpaceByte(tuck_b):
        if true:
          break
      tuck_n = (tuck_n - 1)
  var tuck_out = tuck_slice(t, 0, tuck_n)
  if not tuck_out.ok:
    if true:
      return ""
  return tuck_out.value

proc tuck_trim*(t: sink string): string =
  var tuck_head = tuck_trimStart(t)
  return tuck_trimEnd(tuck_head)

proc tuck_lowerByte*(b: uint8): uint8 =
  var tuck_v = int(b)
  if ((tuck_v >= 65) and (tuck_v <= 90)):
    if true:
      return uint8((tuck_v + 32))
  return b

proc tuck_upperByte*(b: uint8): uint8 =
  var tuck_v = int(b)
  if ((tuck_v >= 97) and (tuck_v <= 122)):
    if true:
      return uint8((tuck_v - 32))
  return b

proc tuck_toLowerAscii*(t: string): string =
  var tuck_out = tuck_noBytes()
  for tuck_i in (0 .. (tuck_rt.byteCount(t) - 1)):
    if true:
      var tuck_b = tuck_rt.byteAt(t, tuck_i)
      var tuck_low = tuck_lowerByte(tuck_b)
      tuck_out.add(tuck_low)
  return tuck_rt.fromBytes(tuck_out)

proc tuck_toUpperAscii*(t: string): string =
  var tuck_out = tuck_noBytes()
  for tuck_i in (0 .. (tuck_rt.byteCount(t) - 1)):
    if true:
      var tuck_b = tuck_rt.byteAt(t, tuck_i)
      var tuck_up = tuck_upperByte(tuck_b)
      tuck_out.add(tuck_up)
  return tuck_rt.fromBytes(tuck_out)

proc tuck_checkAscii*(): int =
  if not tuck_isEmpty(""):
    if true:
      return 1
  if tuck_isEmpty("a"):
    if true:
      return 2
  var tuck_c = tuck_charAtByte("abc", 1)
  if not tuck_c.ok:
    if true:
      return 3
  if (int(tuck_c.value) != 98):
    if true:
      return 4
  var tuck_past = tuck_charAtByte("abc", 9)
  if tuck_past.ok:
    if true:
      return 5
  return tuck_checkSearch()

proc tuck_checkSearch*(): int =
  var tuckfn_at = tuck_find("hello", "ll")
  if not tuckfn_at.ok:
    if true:
      return 6
  if (tuckfn_at.value != 2):
    if true:
      return 7
  var tuck_missing = tuck_find("hello", "zz")
  if tuck_missing.ok:
    if true:
      return 8
  if not tuck_has("hello", "ell"):
    if true:
      return 9
  if not tuck_startsWith("hello", "he"):
    if true:
      return 10
  if not tuck_endsWith("hello", "lo"):
    if true:
      return 11
  if tuck_endsWith("hi", "longer"):
    if true:
      return 12
  return tuck_checkSliceSplit()

proc tuck_checkSliceSplit*(): int =
  var tuck_s = tuck_slice("hello", 1, 3)
  if not tuck_s.ok:
    if true:
      return 13
  if (tuck_s.value != "el"):
    if true:
      return 14
  var tuck_bad = tuck_slice("hi", 0, 99)
  if tuck_bad.ok:
    if true:
      return 15
  var tuck_parts = tuck_split("a,b,c", ",")
  if (tuck_rt.count(tuck_parts) != 3):
    if true:
      return 16
  if (tuck_rt.tuckAt(tuck_parts, 0) != "a"):
    if true:
      return 17
  if (tuck_rt.tuckAt(tuck_parts, 2) != "c"):
    if true:
      return 18
  return tuck_checkTrimCase()

proc tuck_checkTrimCase*(): int =
  if (tuck_trim("  hi  ") != "hi"):
    if true:
      return 19
  if (tuck_trimStart("  hi") != "hi"):
    if true:
      return 20
  if (tuck_trimEnd("hi  ") != "hi"):
    if true:
      return 21
  if (tuck_trim("   ") != ""):
    if true:
      return 22
  if (tuck_toLowerAscii("AbC") != "abc"):
    if true:
      return 23
  if (tuck_toUpperAscii("AbC") != "ABC"):
    if true:
      return 24
  return tuck_checkRunes()

proc tuck_checkRunes*(): int =
  var tuck_s = "héllo"
  if (tuck_rt.byteCount(tuck_s) != 6):
    if true:
      return 25
  if (tuck_runeCount(tuck_s) != 5):
    if true:
      return 26
  var tuck_r = tuck_runeAt(tuck_s, 1)
  if not tuck_r.ok:
    if true:
      return 27
  if (int(tuck_r.value) != 233):
    if true:
      return 28
  var tuck_rs = tuck_runes(tuck_s)
  if (tuck_rt.count(tuck_rs) != 5):
    if true:
      return 29
  var tuck_rs2 = tuck_runes(tuck_s)
  if (tuck_fromRunes(tuck_rs2) != tuck_s):
    if true:
      return 30
  return 0

proc tuck_main*(): int =
  return tuck_checkAscii()


when isMainModule:
  quit(tuck_main())
