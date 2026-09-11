#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import str "./mod_str"

tuck_Builder :: struct {
	chunks: [dynamic]string,
}

tuck_add :: proc (b: tuck_Builder, text: string) -> tuck_Builder {
  b := b
  b.chunks = rt.tuckSeqCopy(b.chunks)
  return tuck_add_moved(b, text)
}

tuck_add_moved :: proc (b: tuck_Builder, text: string) -> tuck_Builder {
  tuck_xs := b.chunks
  append(&tuck_xs, text)
  return tuck_Builder{chunks = tuck_xs}
}

tuck_built :: proc (b: tuck_Builder) -> string {
  return str.joinStr(b.chunks, "")
}

tuck_builtWith :: proc (b: tuck_Builder, sep: string) -> string {
  return str.joinStr(b.chunks, sep)
}

tuck_pieces :: proc (b: tuck_Builder) -> int {
  return len(b.chunks)
}

tuck_clearBuilder :: proc (b: tuck_Builder) -> tuck_Builder {
  b := b
  b.chunks = rt.tuckSeqCopy(b.chunks)
  return tuck_clearBuilder_moved(b)
}

tuck_clearBuilder_moved :: proc (b: tuck_Builder) -> tuck_Builder {
  tuck_empty: [dynamic]string = [dynamic]string{}
  return tuck_Builder{chunks = tuck_empty}
}

tuck_append :: proc (t: string, other: string) -> string {
  return rt.tuckConcat(t, other)
}

tuck_clear :: proc (t: string) -> string {
  return ""
}

tuck_join :: proc (parts: [dynamic]string, sep: string) -> string {
  return str.joinStr(parts, sep)
}

tuck_slice :: proc (t: string, fromByte: int, toByte: int) -> string {
  tuck_b: tuck_Builder = tuck_Builder{chunks = [dynamic]string{}}; tuck_b.chunks = rt.tuckSeqCopy(tuck_b.chunks)
  for tuck_i in (fromByte ..= (toByte - 1)) {
      if ((tuck_i >= 0) && (tuck_i < len(t))) {
          tuck_ch := str.charAt(t, tuck_i)
          tuck_b = tuck_add_moved(tuck_b, tuck_ch)
      }
  }
  return tuck_built(tuck_b)
}

tuck_repeat :: proc (t: string, times: int) -> string {
  tuck_b: tuck_Builder = tuck_Builder{chunks = [dynamic]string{}}; tuck_b.chunks = rt.tuckSeqCopy(tuck_b.chunks)
  for tuck_i in (0 ..= (times - 1)) {
      tuck_b = tuck_add_moved(tuck_b, t)
  }
  return tuck_built(tuck_b)
}

tuck_insertAt :: proc (t: string, index: int, other: string) -> string {
  tuck_head := tuck_slice(t, 0, index)
  tuck_tail := tuck_slice(t, index, len(t))
  return rt.tuckConcat(rt.tuckConcat(tuck_head, other), tuck_tail)
}

tuck_removeRange :: proc (t: string, fromByte: int, toByte: int) -> string {
  tuck_head := tuck_slice(t, 0, fromByte)
  tuck_tail := tuck_slice(t, toByte, len(t))
  return rt.tuckConcat(tuck_head, tuck_tail)
}

tuck_padLeft :: proc (t: string, width: int, fill: string) -> string {
  tuck_b: tuck_Builder = tuck_Builder{chunks = [dynamic]string{}}; tuck_b.chunks = rt.tuckSeqCopy(tuck_b.chunks)
  for tuck_i in (0 ..= ((width - len(t)) - 1)) {
      tuck_b = tuck_add_moved(tuck_b, fill)
  }
  tuck_b = tuck_add_moved(tuck_b, t)
  return tuck_built(tuck_b)
}

tuck_padRight :: proc (t: string, width: int, fill: string) -> string {
  tuck_b: tuck_Builder = tuck_Builder{chunks = [dynamic]string{}}; tuck_b.chunks = rt.tuckSeqCopy(tuck_b.chunks)
  tuck_b = tuck_add_moved(tuck_b, t)
  for tuck_i in (0 ..= ((width - len(t)) - 1)) {
      tuck_b = tuck_add_moved(tuck_b, fill)
  }
  return tuck_built(tuck_b)
}

tuck_matchesAt :: proc (t: string, at: int, what: string) -> bool {
  if ((at + len(what)) > len(t)) {
      return false
  }
  for tuck_i in (0 ..= (len(what) - 1)) {
      if (str.charAt(t, (at + tuck_i)) != str.charAt(what, tuck_i)) {
          return false
      }
  }
  return true
}

tuck_indexOf :: proc (t: string, what: string) -> rt.TuckResult(int) {
  if (len(what) == 0) {
      return rt.tok(0)
  }
  for tuck_i in (0 ..= (len(t) - len(what))) {
      if tuck_matchesAt(t, tuck_i, what) {
          return rt.tok(tuck_i)
      }
  }
  return rt.tnone(int)
}

tuck_contains :: proc (t: string, what: string) -> bool {
  tuckfn_at := tuck_indexOf(t, what)
  return (tuckfn_at.status == .Ok)
}

tuck_replace :: proc (t: string, what: string, into: string) -> string {
  if (len(what) == 0) {
      return t
  }
  tuck_b: tuck_Builder = tuck_Builder{chunks = [dynamic]string{}}; tuck_b.chunks = rt.tuckSeqCopy(tuck_b.chunks)
  tuck_i := 0
  for (tuck_i < len(t)) {
      if tuck_matchesAt(t, tuck_i, what) {
          tuck_b = tuck_add_moved(tuck_b, into)
          tuck_i = (tuck_i + len(what))
      } else {
          tuck_ch := str.charAt(t, tuck_i)
          tuck_b = tuck_add_moved(tuck_b, tuck_ch)
          tuck_i = (tuck_i + 1)
      }
  }
  return tuck_built(tuck_b)
}

tuck_checkBuilder :: proc () -> int {
  tuck_b: tuck_Builder = tuck_Builder{chunks = [dynamic]string{}}; tuck_b.chunks = rt.tuckSeqCopy(tuck_b.chunks)
  tuck_b = tuck_add_moved(tuck_b, "a")
  tuck_b = tuck_add_moved(tuck_b, "b")
  tuck_b = tuck_add_moved(tuck_b, "c")
  if (tuck_pieces(tuck_b) != 3) {
      return 1
  }
  if (tuck_built(tuck_b) != "abc") {
      return 2
  }
  if (tuck_builtWith(tuck_b, "-") != "a-b-c") {
      return 3
  }
  tuck_empty := tuck_clearBuilder(tuck_b); tuck_empty.chunks = rt.tuckSeqCopy(tuck_empty.chunks)
  if (tuck_pieces(tuck_empty) != 0) {
      return 4
  }
  if (tuck_built(tuck_empty) != "") {
      return 5
  }
  return tuck_checkSlice()
}

tuck_checkSlice :: proc () -> int {
  if (tuck_slice("hello", 1, 3) != "el") {
      return 6
  }
  if (tuck_slice("hi", 0, 99) != "hi") {
      return 7
  }
  if (tuck_repeat("ab", 3) != "ababab") {
      return 8
  }
  if (tuck_insertAt("hello", 2, "XY") != "heXYllo") {
      return 9
  }
  if (tuck_removeRange("hello", 1, 3) != "hlo") {
      return 10
  }
  return tuck_checkPadAndReplace()
}

tuck_checkPadAndReplace :: proc () -> int {
  if (tuck_padLeft("7", 3, "0") != "007") {
      return 11
  }
  if (tuck_padRight("7", 3, ".") != "7..") {
      return 12
  }
  if (tuck_padLeft("abcd", 2, "0") != "abcd") {
      return 13
  }
  if (tuck_replace("a,b,c", ",", ";") != "a;b;c") {
      return 14
  }
  if (tuck_replace("aaa", "aa", "b") != "ba") {
      return 15
  }
  tuck_parts: [dynamic]string = [dynamic]string{"x", "y"}
  if (tuck_join(tuck_parts, "+") != "x+y") {
      return 16
  }
  return tuck_checkSearch()
}

tuck_checkSearch :: proc () -> int {
  tuckfn_at := tuck_indexOf("hello", "ll")
  if !(tuckfn_at.status == .Ok) {
      return 17
  }
  if (tuckfn_at.value != 2) {
      return 18
  }
  tuck_missing := tuck_indexOf("hello", "zz")
  if (tuck_missing.status == .Ok) {
      return 19
  }
  if !tuck_contains("hello", "hell") {
      return 20
  }
  if (tuck_append("abc", "d") != "abcd") {
      return 21
  }
  if (tuck_clear("abc") != "") {
      return 22
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_checkBuilder()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
