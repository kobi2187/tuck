#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

TRec_rest_value :: struct ($T_rest: typeid, $T_value: typeid) {
	rest: T_rest,
	value: T_value,
}

tuck_count :: proc (items: [dynamic]$T) -> int {
  return len(items)
}

tuck_isEmpty :: proc (items: [dynamic]$T) -> bool {
  return (len(items) == 0)
}

tuckfn_at :: proc (items: [dynamic]$T, index: int) -> rt.TuckResult(T) {
  if ((index < 0) || (index >= len(items))) {
      return rt.tnone(T)
  }
  return rt.tok(rt.tuckAt(items, index))
}

tuck_first :: proc (items: [dynamic]$T) -> rt.TuckResult(T) {
  return tuckfn_at(items, 0)
}

tuck_last :: proc (items: [dynamic]$T) -> rt.TuckResult(T) {
  return tuckfn_at(items, (len(items) - 1))
}

tuckfn_setAt :: proc (items: [dynamic]$T, index: int, value: T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuckfn_setAt_moved(items, index, value)
}

tuckfn_setAt_moved :: proc (items: [dynamic]$T, index: int, value: T) -> [dynamic]T {
  if ((index < 0) || (index >= len(items))) {
      return items
  }
  tuck_out := items
  rt.tuckSetAt(tuck_out, index, value)
  return tuck_out
}

tuck_clear :: proc (items: [dynamic]$T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_clear_moved(items)
}

tuck_clear_moved :: proc (items: [dynamic]$T) -> [dynamic]T {
  tuck_empty: [dynamic]T = [dynamic]T{}
  return tuck_empty
}

tuck_has :: proc (items: [dynamic]$T, value: T) -> bool {
  for tuck_i in (0 ..= (len(items) - 1)) {
      if (rt.tuckAt(items, tuck_i) == value) {
          return true
      }
  }
  return false
}

tuck_indexOf :: proc (items: [dynamic]$T, value: T) -> rt.TuckResult(int) {
  for tuck_i in (0 ..= (len(items) - 1)) {
      if (rt.tuckAt(items, tuck_i) == value) {
          return rt.tok(tuck_i)
      }
  }
  return rt.tnone(int)
}

tuck_insertAt :: proc (items: [dynamic]$T, index: int, value: T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_insertAt_moved(items, index, value)
}

tuck_insertAt_moved :: proc (items: [dynamic]$T, index: int, value: T) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (len(items) - 1)) {
      if (tuck_i == index) {
          append(&tuck_out, value)
      }
      append(&tuck_out, rt.tuckAt(items, tuck_i))
  }
  if (index >= len(items)) {
      append(&tuck_out, value)
  }
  return tuck_out
}

tuck_removeAt :: proc (items: [dynamic]$T, index: int) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_removeAt_moved(items, index)
}

tuck_removeAt_moved :: proc (items: [dynamic]$T, index: int) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (len(items) - 1)) {
      if (tuck_i != index) {
          append(&tuck_out, rt.tuckAt(items, tuck_i))
      }
  }
  return tuck_out
}

tuck_pop :: proc (items: [dynamic]$T) -> rt.TuckResult(TRec_rest_value([dynamic]T, T)) {
  if (len(items) == 0) {
      return rt.tnone(TRec_rest_value([dynamic]T, T))
  }
  tuck_top := rt.tuckAt(items, (len(items) - 1))
  tuck_rest := rt.tuckSeqCopy(tuck_removeAt(items, (len(items) - 1)))
  return rt.tok(TRec_rest_value([dynamic]T, T){rest = tuck_rest, value = tuck_top})
}

tuck_checkReads :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{10, 20, 30}
  if (tuck_count(tuck_xs) != 3) {
      return 1
  }
  tuck_empty: [dynamic]int = [dynamic]int{}
  if !tuck_isEmpty(tuck_empty) {
      return 2
  }
  tuck_got := tuckfn_at(tuck_xs, 1)
  if !(tuck_got.status == .Ok) {
      return 3
  }
  if (tuck_got.value != 20) {
      return 4
  }
  tuck_past := tuckfn_at(tuck_xs, 9)
  if (tuck_past.status == .Ok) {
      return 5
  }
  return tuck_checkEnds()
}

tuck_checkEnds :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{10, 20, 30}
  tuck_f := tuck_first(tuck_xs)
  if !(tuck_f.status == .Ok) {
      return 6
  }
  if (tuck_f.value != 10) {
      return 7
  }
  tuck_l := tuck_last(tuck_xs)
  if !(tuck_l.status == .Ok) {
      return 8
  }
  if (tuck_l.value != 30) {
      return 9
  }
  tuck_empty: [dynamic]int = [dynamic]int{}
  tuck_absent := tuck_first(tuck_empty)
  if (tuck_absent.status == .Ok) {
      return 10
  }
  return tuck_checkSearch()
}

tuck_checkSearch :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{10, 20, 30}
  if !tuck_has(tuck_xs, 20) {
      return 11
  }
  if tuck_has(tuck_xs, 99) {
      return 12
  }
  tuck_idx := tuck_indexOf(tuck_xs, 30)
  if !(tuck_idx.status == .Ok) {
      return 13
  }
  if (tuck_idx.value != 2) {
      return 14
  }
  tuck_missing := tuck_indexOf(tuck_xs, 99)
  if (tuck_missing.status == .Ok) {
      return 15
  }
  return tuck_checkEdits()
}

tuck_checkEdits :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{10, 20, 30}
  tuck_set := rt.tuckSeqCopy(tuckfn_setAt(tuck_xs, 1, 99))
  if (rt.tuckAt(tuck_set, 1) != 99) {
      return 16
  }
  if (rt.tuckAt(tuck_xs, 1) != 20) {
      return 17
  }
  tuck_ins := rt.tuckSeqCopy(tuck_insertAt(tuck_xs, 1, 15))
  if (len(tuck_ins) != 4) {
      return 18
  }
  if (rt.tuckAt(tuck_ins, 1) != 15) {
      return 19
  }
  tuck_del := rt.tuckSeqCopy(tuck_removeAt(tuck_xs, 0))
  if (len(tuck_del) != 2) {
      return 20
  }
  if (rt.tuckAt(tuck_del, 0) != 20) {
      return 21
  }
  return tuck_checkPop()
}

tuck_checkPop :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{10, 20, 30}
  tuck_p := tuck_pop(tuck_xs)
  if !(tuck_p.status == .Ok) {
      return 22
  }
  if (tuck_p.value.value != 30) {
      return 23
  }
  if (len(tuck_p.value.rest) != 2) {
      return 24
  }
  tuck_empty: [dynamic]int = [dynamic]int{}
  tuck_absent := tuck_pop(tuck_empty)
  if (tuck_absent.status == .Ok) {
      return 25
  }
  tuck_cleared := rt.tuckSeqCopy(tuck_clear(tuck_xs))
  if (len(tuck_cleared) != 0) {
      return 26
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_checkReads()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
