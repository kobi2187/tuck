{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq
import str

proc tuck_add*(b: sink tuck_Builder, text: sink string): tuck_Builder
proc tuck_built*(b: sink tuck_Builder): string
proc tuck_builtWith*(b: sink tuck_Builder, sep: sink string): string
proc tuck_pieces*(b: sink tuck_Builder): int
proc tuck_clearBuilder*(b: tuck_Builder): tuck_Builder
proc tuck_append*(t: sink string, other: sink string): string
proc tuck_clear*(t: string): string
proc tuck_join*(parts: sink seq[string], sep: sink string): string
proc tuck_slice*(t: string, fromByte: int, toByte: int): string
proc tuck_repeat*(t: string, times: int): string
proc tuck_insertAt*(t: sink string, index: int, other: sink string): string
proc tuck_removeRange*(t: sink string, fromByte: int, toByte: int): string
proc tuck_padLeft*(t: string, width: int, fill: string): string
proc tuck_padRight*(t: string, width: int, fill: string): string
proc tuck_matchesAt*(t: string, at: int, what: string): bool
proc tuck_indexOf*(t: string, what: string): TuckResult[int]
proc tuck_contains*(t: sink string, what: sink string): bool
proc tuck_replace*(t: string, what: string, into: string): string
proc tuck_checkBuilder*(): int
proc tuck_checkSlice*(): int
proc tuck_checkPadAndReplace*(): int
proc tuck_checkSearch*(): int
proc tuck_main*(): int

type tuck_Builder* = object
  chunks*: seq[string]

proc tuck_add*(b: sink tuck_Builder, text: sink string): tuck_Builder =
  var tuck_xs = b.chunks
  tuck_xs.add(text)
  return tuck_Builder(chunks: tuck_xs)

proc tuck_built*(b: sink tuck_Builder): string =
  return tuck_rt.joinStr(b.chunks, "")

proc tuck_builtWith*(b: sink tuck_Builder, sep: sink string): string =
  return tuck_rt.joinStr(b.chunks, sep)

proc tuck_pieces*(b: sink tuck_Builder): int =
  return b.chunks.len

proc tuck_clearBuilder*(b: tuck_Builder): tuck_Builder =
  var tuck_empty: seq[string] = @[]
  return tuck_Builder(chunks: tuck_empty)

proc tuck_append*(t: sink string, other: sink string): string =
  return tuckConcat(t, other)

proc tuck_clear*(t: string): string =
  return ""

proc tuck_join*(parts: sink seq[string], sep: sink string): string =
  return tuck_rt.joinStr(parts, sep)

proc tuck_slice*(t: string, fromByte: int, toByte: int): string =
  var tuck_b: tuck_Builder = tuck_Builder(chunks: @[])
  for tuck_i in (fromByte .. (toByte - 1)):
    if true:
      if ((tuck_i >= 0) and (tuck_i < t.len)):
        if true:
          var tuck_ch = tuck_rt.charAt(t, tuck_i)
          tuck_b = tuck_add(tuck_b, tuck_ch)
  return tuck_built(tuck_b)

proc tuck_repeat*(t: string, times: int): string =
  var tuck_b: tuck_Builder = tuck_Builder(chunks: @[])
  for tuck_i in (0 .. (times - 1)):
    if true:
      tuck_b = tuck_add(tuck_b, t)
  return tuck_built(tuck_b)

proc tuck_insertAt*(t: sink string, index: int, other: sink string): string =
  var tuck_head = tuck_slice(t, 0, index)
  var tuck_tail = tuck_slice(t, index, t.len)
  return tuckConcat(tuckConcat(tuck_head, other), tuck_tail)

proc tuck_removeRange*(t: sink string, fromByte: int, toByte: int): string =
  var tuck_head = tuck_slice(t, 0, fromByte)
  var tuck_tail = tuck_slice(t, toByte, t.len)
  return tuckConcat(tuck_head, tuck_tail)

proc tuck_padLeft*(t: string, width: int, fill: string): string =
  var tuck_b: tuck_Builder = tuck_Builder(chunks: @[])
  for tuck_i in (0 .. ((width - t.len) - 1)):
    if true:
      tuck_b = tuck_add(tuck_b, fill)
  tuck_b = tuck_add(tuck_b, t)
  return tuck_built(tuck_b)

proc tuck_padRight*(t: string, width: int, fill: string): string =
  var tuck_b: tuck_Builder = tuck_Builder(chunks: @[])
  tuck_b = tuck_add(tuck_b, t)
  for tuck_i in (0 .. ((width - t.len) - 1)):
    if true:
      tuck_b = tuck_add(tuck_b, fill)
  return tuck_built(tuck_b)

proc tuck_matchesAt*(t: string, at: int, what: string): bool =
  if ((at + what.len) > t.len):
    if true:
      return false
  for tuck_i in (0 .. (what.len - 1)):
    if true:
      if (tuck_rt.charAt(t, (at + tuck_i)) != tuck_rt.charAt(what, tuck_i)):
        if true:
          return false
  return true

proc tuck_indexOf*(t: string, what: string): TuckResult[int] =
  if (what.len == 0):
    if true:
      return tok(0)
  for tuck_i in (0 .. (t.len - what.len)):
    if true:
      if tuck_matchesAt(t, tuck_i, what):
        if true:
          return tok(tuck_i)
  return tnone[int]()

proc tuck_contains*(t: sink string, what: sink string): bool =
  var tuckfn_at = tuck_indexOf(t, what)
  return tuckfn_at.ok

proc tuck_replace*(t: string, what: string, into: string): string =
  if (what.len == 0):
    if true:
      return t
  var tuck_b: tuck_Builder = tuck_Builder(chunks: @[])
  var tuck_i = 0
  while (tuck_i < t.len):
    if true:
      if tuck_matchesAt(t, tuck_i, what):
        if true:
          tuck_b = tuck_add(tuck_b, into)
          tuck_i = (tuck_i + what.len)
      else:
        if true:
          var tuck_ch = tuck_rt.charAt(t, tuck_i)
          tuck_b = tuck_add(tuck_b, tuck_ch)
          tuck_i = (tuck_i + 1)
  return tuck_built(tuck_b)

proc tuck_checkBuilder*(): int =
  var tuck_b: tuck_Builder = tuck_Builder(chunks: @[])
  tuck_b = tuck_add(tuck_b, "a")
  tuck_b = tuck_add(tuck_b, "b")
  tuck_b = tuck_add(tuck_b, "c")
  if (tuck_pieces(tuck_b) != 3):
    if true:
      return 1
  if (tuck_built(tuck_b) != "abc"):
    if true:
      return 2
  if (tuck_builtWith(tuck_b, "-") != "a-b-c"):
    if true:
      return 3
  var tuck_empty = tuck_clearBuilder(tuck_b)
  if (tuck_pieces(tuck_empty) != 0):
    if true:
      return 4
  if (tuck_built(tuck_empty) != ""):
    if true:
      return 5
  return tuck_checkSlice()

proc tuck_checkSlice*(): int =
  if (tuck_slice("hello", 1, 3) != "el"):
    if true:
      return 6
  if (tuck_slice("hi", 0, 99) != "hi"):
    if true:
      return 7
  if (tuck_repeat("ab", 3) != "ababab"):
    if true:
      return 8
  if (tuck_insertAt("hello", 2, "XY") != "heXYllo"):
    if true:
      return 9
  if (tuck_removeRange("hello", 1, 3) != "hlo"):
    if true:
      return 10
  return tuck_checkPadAndReplace()

proc tuck_checkPadAndReplace*(): int =
  if (tuck_padLeft("7", 3, "0") != "007"):
    if true:
      return 11
  if (tuck_padRight("7", 3, ".") != "7.."):
    if true:
      return 12
  if (tuck_padLeft("abcd", 2, "0") != "abcd"):
    if true:
      return 13
  if (tuck_replace("a,b,c", ",", ";") != "a;b;c"):
    if true:
      return 14
  if (tuck_replace("aaa", "aa", "b") != "ba"):
    if true:
      return 15
  var tuck_parts: seq[string] = @["x", "y"]
  if (tuck_join(tuck_parts, "+") != "x+y"):
    if true:
      return 16
  return tuck_checkSearch()

proc tuck_checkSearch*(): int =
  var tuckfn_at = tuck_indexOf("hello", "ll")
  if not tuckfn_at.ok:
    if true:
      return 17
  if (tuckfn_at.value != 2):
    if true:
      return 18
  var tuck_missing = tuck_indexOf("hello", "zz")
  if tuck_missing.ok:
    if true:
      return 19
  if not tuck_contains("hello", "hell"):
    if true:
      return 20
  if (tuck_append("abc", "d") != "abcd"):
    if true:
      return 21
  if (tuck_clear("abc") != ""):
    if true:
      return 22
  return 0

proc tuck_main*(): int =
  return tuck_checkBuilder()


when isMainModule:
  quit(tuck_main())
