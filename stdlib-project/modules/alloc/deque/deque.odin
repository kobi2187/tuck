#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

TRec_rest_value :: struct ($T_rest: typeid, $T_value: typeid) {
	rest: T_rest,
	value: T_value,
}

tuck_Ring :: struct($T: typeid) {
	items: [dynamic]T,
}

tuck_count :: proc (r: tuck_Ring($T)) -> int {
  return len(r.items)
}

tuck_isEmpty :: proc (r: tuck_Ring($T)) -> bool {
  return (len(r.items) == 0)
}

tuck_first :: proc (r: tuck_Ring($T)) -> rt.TuckResult(T) {
  if (len(r.items) == 0) {
      return rt.tnone(T)
  }
  return rt.tok(rt.tuckAt(r.items, 0))
}

tuck_last :: proc (r: tuck_Ring($T)) -> rt.TuckResult(T) {
  if (len(r.items) == 0) {
      return rt.tnone(T)
  }
  return rt.tok(rt.tuckAt(r.items, (len(r.items) - 1)))
}

tuck_pushBack :: proc (r: tuck_Ring($T), value: T) -> tuck_Ring(T) {
  r := r
  r.items = rt.tuckSeqCopy(r.items)
  return tuck_pushBack_moved(r, value)
}

tuck_pushBack_moved :: proc (r: tuck_Ring($T), value: T) -> tuck_Ring(T) {
  tuck_xs := r.items
  append(&tuck_xs, value)
  return tuck_Ring(T){items = tuck_xs}
}

tuck_pushFront :: proc (r: tuck_Ring($T), value: T) -> tuck_Ring(T) {
  r := r
  r.items = rt.tuckSeqCopy(r.items)
  return tuck_pushFront_moved(r, value)
}

tuck_pushFront_moved :: proc (r: tuck_Ring($T), value: T) -> tuck_Ring(T) {
  tuck_xs: [dynamic]T = [dynamic]T{}
  append(&tuck_xs, value)
  for tuck_i in (0 ..= (len(r.items) - 1)) {
      append(&tuck_xs, rt.tuckAt(r.items, tuck_i))
  }
  return tuck_Ring(T){items = tuck_xs}
}

tuck_popBack :: proc (r: tuck_Ring($T)) -> rt.TuckResult(TRec_rest_value(tuck_Ring(T), T)) {
  tuck_n := len(r.items)
  if (tuck_n == 0) {
      return rt.tnone(TRec_rest_value(tuck_Ring(T), T))
  }
  tuck_top := rt.tuckAt(r.items, (tuck_n - 1))
  tuck_xs: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (tuck_n - 2)) {
      append(&tuck_xs, rt.tuckAt(r.items, tuck_i))
  }
  tuck_rest := tuck_Ring(T){items = tuck_xs}
  return rt.tok(TRec_rest_value(tuck_Ring(T), T){rest = tuck_rest, value = tuck_top})
}

tuck_popFront :: proc (r: tuck_Ring($T)) -> rt.TuckResult(TRec_rest_value(tuck_Ring(T), T)) {
  tuck_n := len(r.items)
  if (tuck_n == 0) {
      return rt.tnone(TRec_rest_value(tuck_Ring(T), T))
  }
  tuck_head := rt.tuckAt(r.items, 0)
  tuck_xs: [dynamic]T = [dynamic]T{}
  for tuck_i in (1 ..= (tuck_n - 1)) {
      append(&tuck_xs, rt.tuckAt(r.items, tuck_i))
  }
  tuck_rest := tuck_Ring(T){items = tuck_xs}
  return rt.tok(TRec_rest_value(tuck_Ring(T), T){rest = tuck_rest, value = tuck_head})
}

tuck_clear :: proc (r: tuck_Ring($T)) -> tuck_Ring(T) {
  r := r
  r.items = rt.tuckSeqCopy(r.items)
  return tuck_clear_moved(r)
}

tuck_clear_moved :: proc (r: tuck_Ring($T)) -> tuck_Ring(T) {
  tuck_empty: [dynamic]T = [dynamic]T{}
  return tuck_Ring(T){items = tuck_empty}
}

tuck_toSeq :: proc (r: tuck_Ring($T)) -> [dynamic]T {
  return r.items
}

tuck_checkEnds :: proc () -> int {
  tuck_q: tuck_Ring(int) = tuck_Ring(int){items = [dynamic]int{}}
  if !tuck_isEmpty(tuck_q) {
      return 1
  }
  tuck_noEnd := tuck_first(tuck_q)
  if (tuck_noEnd.status == .Ok) {
      return 2
  }
  tuck_q = tuck_pushBack_moved(tuck_q, 2)
  tuck_q = tuck_pushBack_moved(tuck_q, 3)
  tuck_q = tuck_pushFront_moved(tuck_q, 1)
  if (tuck_count(tuck_q) != 3) {
      return 3
  }
  tuck_f := tuck_first(tuck_q)
  if !(tuck_f.status == .Ok) {
      return 4
  }
  if (tuck_f.value != 1) {
      return 5
  }
  tuck_l := tuck_last(tuck_q)
  if !(tuck_l.status == .Ok) {
      return 6
  }
  if (tuck_l.value != 3) {
      return 7
  }
  return tuck_checkPops()
}

tuck_threeUp :: proc () -> tuck_Ring(int) {
  tuck_q: tuck_Ring(int) = tuck_Ring(int){items = [dynamic]int{}}
  tuck_q = tuck_pushBack_moved(tuck_q, 1)
  tuck_q = tuck_pushBack_moved(tuck_q, 2)
  return tuck_pushBack(tuck_q, 3)
}

tuck_checkPops :: proc () -> int {
  tuck_q := tuck_threeUp()
  tuck_back := tuck_popBack(tuck_q)
  if !(tuck_back.status == .Ok) {
      return 8
  }
  if (tuck_back.value.value != 3) {
      return 9
  }
  if (tuck_count(tuck_back.value.rest) != 2) {
      return 10
  }
  tuck_front := tuck_popFront(tuck_q)
  if !(tuck_front.status == .Ok) {
      return 11
  }
  if (tuck_front.value.value != 1) {
      return 12
  }
  if (tuck_count(tuck_front.value.rest) != 2) {
      return 13
  }
  if (tuck_count(tuck_q) != 3) {
      return 14
  }
  return tuck_checkEmptyPops()
}

tuck_checkEmptyPops :: proc () -> int {
  tuck_empty: tuck_Ring(int) = tuck_Ring(int){items = [dynamic]int{}}
  tuck_b := tuck_popBack(tuck_empty)
  if (tuck_b.status == .Ok) {
      return 15
  }
  tuck_f := tuck_popFront(tuck_empty)
  if (tuck_f.status == .Ok) {
      return 16
  }
  tuck_cleared := tuck_clear(tuck_threeUp())
  if (tuck_count(tuck_cleared) != 0) {
      return 17
  }
  tuck_xs := rt.tuckSeqCopy(tuck_toSeq(tuck_threeUp()))
  if (len(tuck_xs) != 3) {
      return 18
  }
  if (rt.tuckAt(tuck_xs, 0) != 1) {
      return 19
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_checkEnds()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
