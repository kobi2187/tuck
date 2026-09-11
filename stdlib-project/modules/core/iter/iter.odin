#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import seq "./mod_seq"

TRec_index_value :: struct ($T_index: typeid, $T_value: typeid) {
	index: T_index,
	value: T_value,
}

TRec_left_right :: struct ($T_left: typeid, $T_right: typeid) {
	left: T_left,
	right: T_right,
}

tuck_map :: proc (items: [dynamic]$T, f: proc(T) -> $U) -> [dynamic]U {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_map_moved(items, f)
}

tuck_map_moved :: proc (items: [dynamic]$T, f: proc(T) -> $U) -> [dynamic]U {
  tuck_out: [dynamic]U = [dynamic]U{}
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_v := f(rt.tuckAt(items, tuck_i))
      append(&tuck_out, tuck_v)
  }
  return tuck_out
}

tuck_filter :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_filter_moved(items, test)
}

tuck_filter_moved :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_v := rt.tuckAt(items, tuck_i)
      if test(tuck_v) {
          append(&tuck_out, tuck_v)
      }
  }
  return tuck_out
}

tuck_reject :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_reject_moved(items, test)
}

tuck_reject_moved :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_v := rt.tuckAt(items, tuck_i)
      if !test(tuck_v) {
          append(&tuck_out, tuck_v)
      }
  }
  return tuck_out
}

tuck_take :: proc (items: [dynamic]$T, n: int) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_take_moved(items, n)
}

tuck_take_moved :: proc (items: [dynamic]$T, n: int) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  tuck_i := 0
  for ((tuck_i < seq.len(items)) && (tuck_i < n)) {
      append(&tuck_out, rt.tuckAt(items, tuck_i))
      tuck_i = (tuck_i + 1)
  }
  return tuck_out
}

tuck_skip :: proc (items: [dynamic]$T, n: int) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_skip_moved(items, n)
}

tuck_skip_moved :: proc (items: [dynamic]$T, n: int) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  tuck_i := n
  for (tuck_i < seq.len(items)) {
      append(&tuck_out, rt.tuckAt(items, tuck_i))
      tuck_i = (tuck_i + 1)
  }
  return tuck_out
}

tuck_numbered :: proc (items: [dynamic]$T) -> [dynamic]TRec_index_value(int, T) {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_numbered_moved(items)
}

tuck_numbered_moved :: proc (items: [dynamic]$T) -> [dynamic]TRec_index_value(int, T) {
  tuck_out: [dynamic]TRec_index_value(int, T) = [dynamic]TRec_index_value(int, T){}
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      append(&tuck_out, TRec_index_value(int, T){index = tuck_i, value = rt.tuckAt(items, tuck_i)})
  }
  return tuck_out
}

tuck_zip :: proc (items: [dynamic]$T, other: [dynamic]$U) -> [dynamic]TRec_left_right(T, U) {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_zip_moved(items, other)
}

tuck_zip_moved :: proc (items: [dynamic]$T, other: [dynamic]$U) -> [dynamic]TRec_left_right(T, U) {
  tuck_out: [dynamic]TRec_left_right(T, U) = [dynamic]TRec_left_right(T, U){}
  tuck_n := seq.len(items)
  if (seq.len(other) < tuck_n) {
      tuck_n = seq.len(other)
  }
  tuck_i := 0
  for (tuck_i < tuck_n) {
      append(&tuck_out, TRec_left_right(T, U){left = rt.tuckAt(items, tuck_i), right = rt.tuckAt(other, tuck_i)})
      tuck_i = (tuck_i + 1)
  }
  return tuck_out
}

tuck_append :: proc (items: [dynamic]$T, other: [dynamic]T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_append_moved(items, other)
}

tuck_append_moved :: proc (items: [dynamic]$T, other: [dynamic]T) -> [dynamic]T {
  tuck_out := items
  for tuck_i in (0 ..= (seq.len(other) - 1)) {
      append(&tuck_out, rt.tuckAt(other, tuck_i))
  }
  return tuck_out
}

tuck_prepend :: proc (items: [dynamic]$T, other: [dynamic]T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_prepend_moved(items, other)
}

tuck_prepend_moved :: proc (items: [dynamic]$T, other: [dynamic]T) -> [dynamic]T {
  tuck_out := rt.tuckSeqCopy(other)
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      append(&tuck_out, rt.tuckAt(items, tuck_i))
  }
  return tuck_out
}

tuckfn_concat :: proc (items: [dynamic][dynamic]$T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuckfn_concat_moved(items)
}

tuckfn_concat_moved :: proc (items: [dynamic][dynamic]$T) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_inner := rt.tuckSeqCopy(rt.tuckAt(items, tuck_i))
      for tuck_j in (0 ..= (seq.len(tuck_inner) - 1)) {
          append(&tuck_out, rt.tuckAt(tuck_inner, tuck_j))
      }
  }
  return tuck_out
}

tuck_reverse :: proc (items: [dynamic]$T) -> [dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_reverse_moved(items)
}

tuck_reverse_moved :: proc (items: [dynamic]$T) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  tuck_i := (seq.len(items) - 1)
  for (tuck_i >= 0) {
      append(&tuck_out, rt.tuckAt(items, tuck_i))
      tuck_i = (tuck_i - 1)
  }
  return tuck_out
}

tuck_reduce :: proc (items: [dynamic]$T, start: $A, combine: proc(A, T) -> A) -> A {
  tuck_acc := start
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_acc = combine(tuck_acc, rt.tuckAt(items, tuck_i))
  }
  return tuck_acc
}

tuck_each :: proc (items: [dynamic]$T, f: proc(T)) {
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      f(rt.tuckAt(items, tuck_i))
  }
}

tuck_find :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> rt.TuckResult(T) {
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_v := rt.tuckAt(items, tuck_i)
      if test(tuck_v) {
          return rt.tok(tuck_v)
      }
  }
  return rt.tnone(T)
}

tuck_any :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> bool {
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      if test(rt.tuckAt(items, tuck_i)) {
          return true
      }
  }
  return false
}

tuck_all :: proc (items: [dynamic]$T, test: proc(T) -> bool) -> bool {
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      if !test(rt.tuckAt(items, tuck_i)) {
          return false
      }
  }
  return true
}

tuck_sum :: proc (items: [dynamic]int) -> int {
  tuck_acc := 0
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      tuck_acc = (tuck_acc + rt.tuckAt(items, tuck_i))
  }
  return tuck_acc
}

tuck_sort :: proc (items: [dynamic]int) -> [dynamic]int {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_sort_moved(items)
}

tuck_sort_moved :: proc (items: [dynamic]int) -> [dynamic]int {
  tuck_out := items
  tuck_i := 1
  for (tuck_i < seq.len(tuck_out)) {
      tuck_key := rt.tuckAt(tuck_out, tuck_i)
      tuck_j := (tuck_i - 1)
      for ((tuck_j >= 0) && (rt.tuckAt(tuck_out, tuck_j) > tuck_key)) {
          seq.setAt(tuck_out, (tuck_j + 1), rt.tuckAt(tuck_out, tuck_j))
          tuck_j = (tuck_j - 1)
      }
      seq.setAt(tuck_out, (tuck_j + 1), tuck_key)
      tuck_i = (tuck_i + 1)
  }
  return tuck_out
}

tuck_isPositive :: proc (x: int) -> bool {
  return (x > 0)
}

tuck_double :: proc (x: int) -> int {
  return (x * 2)
}

tuck_addUp :: proc (acc: int, x: int) -> int {
  return (acc + x)
}

tuck_recordEach :: proc (x: int) {
  return
}

tuck_checkFilterMap :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{(0 - 3), 1, 4, (0 - 1), 5, 9}
  tuck_live := rt.tuckSeqCopy(tuck_filter(tuck_xs, tuck_isPositive))
  if (seq.len(tuck_live) != 4) {
      return 1
  }
  tuck_doubled := rt.tuckSeqCopy(tuck_map(tuck_live, tuck_double))
  if ((rt.tuckAt(tuck_doubled, 0) != 2) || (rt.tuckAt(tuck_doubled, 3) != 18)) {
      return 2
  }
  tuck_gone := rt.tuckSeqCopy(tuck_reject(tuck_xs, tuck_isPositive))
  if (seq.len(tuck_gone) != 2) {
      return 3
  }
  return 0
}

tuck_checkSlices :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{(0 - 3), 1, 4, (0 - 1), 5, 9}
  tuck_first2 := rt.tuckSeqCopy(tuck_take(tuck_xs, 2))
  if ((seq.len(tuck_first2) != 2) || (rt.tuckAt(tuck_first2, 1) != 1)) {
      return 4
  }
  tuck_rest := rt.tuckSeqCopy(tuck_skip(tuck_xs, 2))
  if ((seq.len(tuck_rest) != (seq.len(tuck_xs) - 2)) || (rt.tuckAt(tuck_rest, 0) != 4)) {
      return 5
  }
  tuck_nums := rt.tuckSeqCopy(tuck_numbered(tuck_xs))
  if ((rt.tuckAt(tuck_nums, 0).index != 0) || (rt.tuckAt(tuck_nums, 2).value != 4)) {
      return 6
  }
  return 0
}

tuck_checkJoins :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{(0 - 3), 1, 4, (0 - 1), 5, 9}
  tuck_first2 := rt.tuckSeqCopy(tuck_take(tuck_xs, 2))
  tuck_rest := rt.tuckSeqCopy(tuck_skip(tuck_xs, 2))
  tuck_ys: [dynamic]int = [dynamic]int{10, 20}
  tuck_paired := rt.tuckSeqCopy(tuck_zip(tuck_xs, tuck_ys))
  if ((seq.len(tuck_paired) != 2) || ((rt.tuckAt(tuck_paired, 1).left != 1) || (rt.tuckAt(tuck_paired, 1).right != 20))) {
      return 7
  }
  tuck_joined := rt.tuckSeqCopy(tuck_append(tuck_first2, tuck_rest))
  if (seq.len(tuck_joined) != seq.len(tuck_xs)) {
      return 8
  }
  tuck_front := rt.tuckSeqCopy(tuck_prepend(tuck_rest, tuck_first2))
  if ((seq.len(tuck_front) != seq.len(tuck_xs)) || (rt.tuckAt(tuck_front, 0) != rt.tuckAt(tuck_first2, 0))) {
      return 9
  }
  tuck_nested: [dynamic][dynamic]int = [dynamic][dynamic]int{tuck_first2, tuck_rest}
  tuck_flat := rt.tuckSeqCopy(tuckfn_concat(tuck_nested))
  if (seq.len(tuck_flat) != seq.len(tuck_xs)) {
      return 10
  }
  tuck_backwards := rt.tuckSeqCopy(tuck_reverse(tuck_first2))
  if ((rt.tuckAt(tuck_backwards, 0) != rt.tuckAt(tuck_first2, 1)) || (rt.tuckAt(tuck_backwards, 1) != rt.tuckAt(tuck_first2, 0))) {
      return 11
  }
  return 0
}

tuck_checkAdapters :: proc () -> int {
  tuck_a := tuck_checkFilterMap()
  if (tuck_a != 0) {
      return tuck_a
  }
  tuck_b := tuck_checkSlices()
  if (tuck_b != 0) {
      return tuck_b
  }
  return tuck_checkJoins()
}

tuck_checkReduceFind :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{(0 - 3), 1, 4, (0 - 1), 5, 9}
  tuck_total := tuck_reduce(tuck_xs, 0, tuck_addUp)
  if (tuck_total != 15) {
      return 20
  }
  tuck_each(tuck_xs, tuck_recordEach)
  tuck_hit := tuck_find(tuck_xs, tuck_isPositive)
  if !(tuck_hit.status == .Ok) {
      return 21
  }
  if (tuck_hit.value != 1) {
      return 21
  }
  tuck_noneHit := tuck_find([dynamic]int{(0 - 1), (0 - 2)}, tuck_isPositive)
  if (tuck_noneHit.status == .Ok) {
      return 22
  }
  return 0
}

tuck_checkPredicates :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{(0 - 3), 1, 4, (0 - 1), 5, 9}
  if !tuck_any(tuck_xs, tuck_isPositive) {
      return 23
  }
  if tuck_all(tuck_xs, tuck_isPositive) {
      return 24
  }
  tuck_miss := rt.tuckSeqCopy(tuck_filter(tuck_xs, tuck_isPositive))
  if (tuck_sum(tuck_miss) != 19) {
      return 25
  }
  return 0
}

tuck_checkTerminals :: proc () -> int {
  tuck_a := tuck_checkReduceFind()
  if (tuck_a != 0) {
      return tuck_a
  }
  return tuck_checkPredicates()
}

tuck_checkOrder :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{5, 3, (0 - 1), 4, 4, 9, 0}
  tuck_sorted := rt.tuckSeqCopy(tuck_sort(tuck_xs))
  tuck_i := 1
  for (tuck_i < seq.len(tuck_sorted)) {
      if (rt.tuckAt(tuck_sorted, (tuck_i - 1)) > rt.tuckAt(tuck_sorted, tuck_i)) {
          return 30
      }
      tuck_i = (tuck_i + 1)
  }
  if ((rt.tuckAt(tuck_sorted, 0) != (0 - 1)) || (rt.tuckAt(tuck_sorted, (seq.len(tuck_sorted) - 1)) != 9)) {
      return 31
  }
  return 0
}

tuck_main :: proc () -> int {
  tuck_a := tuck_checkAdapters()
  if (tuck_a != 0) {
      return tuck_a
  }
  tuck_t := tuck_checkTerminals()
  if (tuck_t != 0) {
      return tuck_t
  }
  return tuck_checkOrder()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
