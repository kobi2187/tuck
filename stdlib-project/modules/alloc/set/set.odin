#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import seq "./mod_seq"

tuck_Set :: struct($T: typeid) {
	items: [dynamic]T,
}

tuck_has :: proc (s: tuck_Set($T), value: T) -> bool {
  for tuck_i in (0 ..= (len(s.items) - 1)) {
      if (rt.tuckAt(s.items, tuck_i) == value) {
          return true
      }
  }
  return false
}

tuck_count :: proc (s: tuck_Set($T)) -> int {
  return len(s.items)
}

tuck_toSeq :: proc (s: tuck_Set($T)) -> [dynamic]T {
  return s.items
}

tuck_add :: proc (s: tuck_Set($T), value: T) -> tuck_Set(T) {
  s := s
  s.items = rt.tuckSeqCopy(s.items)
  return tuck_add_moved(s, value)
}

tuck_add_moved :: proc (s: tuck_Set($T), value: T) -> tuck_Set(T) {
  if tuck_has(s, value) {
      return s
  }
  return tuck_Set(T){items = seq.push(s.items, value)}
}

tuck_remove :: proc (s: tuck_Set($T), value: T) -> tuck_Set(T) {
  s := s
  s.items = rt.tuckSeqCopy(s.items)
  return tuck_remove_moved(s, value)
}

tuck_remove_moved :: proc (s: tuck_Set($T), value: T) -> tuck_Set(T) {
  tuck_kept: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (len(s.items) - 1)) {
      tuck_item := rt.tuckAt(s.items, tuck_i)
      if (tuck_item != value) {
          append(&tuck_kept, tuck_item)
      }
  }
  return tuck_Set(T){items = tuck_kept}
}

tuck_union :: proc (a: tuck_Set($T), b: tuck_Set(T)) -> tuck_Set(T) {
  a := a
  a.items = rt.tuckSeqCopy(a.items)
  return tuck_union_moved(a, b)
}

tuck_union_moved :: proc (a: tuck_Set($T), b: tuck_Set(T)) -> tuck_Set(T) {
  tuck_out := a
  for tuck_i in (0 ..= (len(b.items) - 1)) {
      tuck_out = tuck_add_moved(tuck_out, rt.tuckAt(b.items, tuck_i))
  }
  return tuck_out
}

tuck_intersect :: proc (a: tuck_Set($T), b: tuck_Set(T)) -> tuck_Set(T) {
  a := a
  a.items = rt.tuckSeqCopy(a.items)
  return tuck_intersect_moved(a, b)
}

tuck_intersect_moved :: proc (a: tuck_Set($T), b: tuck_Set(T)) -> tuck_Set(T) {
  tuck_out: tuck_Set(T) = tuck_Set(T){items = [dynamic]T{}}
  for tuck_i in (0 ..= (len(a.items) - 1)) {
      tuck_item := rt.tuckAt(a.items, tuck_i)
      if tuck_has(b, tuck_item) {
          tuck_out = tuck_add_moved(tuck_out, tuck_item)
      }
  }
  return tuck_out
}

tuck_difference :: proc (a: tuck_Set($T), b: tuck_Set(T)) -> tuck_Set(T) {
  a := a
  a.items = rt.tuckSeqCopy(a.items)
  return tuck_difference_moved(a, b)
}

tuck_difference_moved :: proc (a: tuck_Set($T), b: tuck_Set(T)) -> tuck_Set(T) {
  tuck_out: tuck_Set(T) = tuck_Set(T){items = [dynamic]T{}}
  for tuck_i in (0 ..= (len(a.items) - 1)) {
      tuck_item := rt.tuckAt(a.items, tuck_i)
      if !tuck_has(b, tuck_item) {
          tuck_out = tuck_add_moved(tuck_out, tuck_item)
      }
  }
  return tuck_out
}

tuck_threeWords :: proc () -> tuck_Set(string) {
  tuck_s: tuck_Set(string) = tuck_Set(string){items = [dynamic]string{}}
  tuck_s = tuck_add_moved(tuck_s, "a")
  tuck_s = tuck_add_moved(tuck_s, "b")
  return tuck_add(tuck_s, "c")
}

tuck_checkBasics :: proc () -> int {
  tuck_s: tuck_Set(string) = tuck_Set(string){items = [dynamic]string{}}
  tuck_s = tuck_add_moved(tuck_s, "a")
  tuck_s = tuck_add_moved(tuck_s, "a")
  if (tuck_count(tuck_s) != 1) {
      return 1
  }
  if !tuck_has(tuck_s, "a") {
      return 2
  }
  if tuck_has(tuck_s, "z") {
      return 3
  }
  return tuck_checkRemove()
}

tuck_checkRemove :: proc () -> int {
  tuck_s := tuck_threeWords()
  if (tuck_count(tuck_s) != 3) {
      return 4
  }
  tuck_s = tuck_remove_moved(tuck_s, "b")
  if (tuck_count(tuck_s) != 2) {
      return 5
  }
  if tuck_has(tuck_s, "b") {
      return 6
  }
  tuck_s = tuck_remove_moved(tuck_s, "zzz")
  if (tuck_count(tuck_s) != 2) {
      return 7
  }
  return 0
}

tuck_twoOnly :: proc () -> tuck_Set(string) {
  tuck_t: tuck_Set(string) = tuck_Set(string){items = [dynamic]string{}}
  tuck_t = tuck_add_moved(tuck_t, "b")
  return tuck_add(tuck_t, "d")
}

tuck_checkAlgebra :: proc () -> int {
  tuck_a := tuck_threeWords()
  tuck_b := tuck_twoOnly()
  tuck_both := tuck_union(tuck_a, tuck_b)
  if (tuck_count(tuck_both) != 4) {
      return 8
  }
  tuck_common := tuck_intersect(tuck_a, tuck_b)
  if (tuck_count(tuck_common) != 1) {
      return 9
  }
  if !tuck_has(tuck_common, "b") {
      return 10
  }
  return tuck_checkDifference(tuck_a, tuck_b)
}

tuck_checkDifference :: proc (a: tuck_Set(string), b: tuck_Set(string)) -> int {
  tuck_only := tuck_difference(a, b)
  if (tuck_count(tuck_only) != 2) {
      return 11
  }
  if tuck_has(tuck_only, "b") {
      return 12
  }
  if !tuck_has(tuck_only, "a") {
      return 13
  }
  tuck_other := tuck_difference(b, a)
  if (tuck_count(tuck_other) != 1) {
      return 14
  }
  tuck_seq := rt.tuckSeqCopy(tuck_toSeq(tuck_other))
  if (len(tuck_seq) != 1) {
      return 15
  }
  return 0
}

tuck_main :: proc () -> int {
  tuck_basics := tuck_checkBasics()
  if (tuck_basics != 0) {
      return tuck_basics
  }
  return tuck_checkAlgebra()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
