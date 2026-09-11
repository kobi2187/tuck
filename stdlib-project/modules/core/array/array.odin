#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"
import seq "./mod_seq"

tuckArrayAt :: proc(items: [$N]$T, index: int) -> T {
	return rt.tuckArrayAt(items, index)
}

tuckArraySetAt :: proc(items: [$N]$T, index: int, value: T) {
	rt.tuckArraySetAt(items, index, value)
}


tuck_atFixed :: proc (items: [$N]$T, index: int) -> rt.TuckResult(T) {
  tuck_n := seq.len(items)
  if ((index < 0) || (index >= tuck_n)) {
      return rt.tnone(T)
  }
  return rt.tok(rt.tuckArrayAt(items, index))
}

tuck_setAtFixed :: proc (items: [$N]$T, index: int, value: T) -> rt.TuckResult([N]T) {
  tuck_out := items
  if ((index < 0) || (index >= seq.len(tuck_out))) {
      return rt.tnone([N]T)
  }
  rt.tuckArraySetAt(&tuck_out, index, value)
  return rt.tok(tuck_out)
}

tuck_countOf :: proc (items: [dynamic]$T, value: T) -> int {
  tuck_n := 0
  for tuck_i in (0 ..= (seq.len(items) - 1)) {
      if (rt.tuckAt(items, tuck_i) == value) {
          tuck_n = (tuck_n + 1)
      }
  }
  return tuck_n
}

tuck_chunk :: proc (items: [dynamic]$T, size: int) -> [dynamic][dynamic]T {
  items := items
  items = rt.tuckSeqCopy(items)
  return tuck_chunk_moved(items, size)
}

tuck_chunk_moved :: proc (items: [dynamic]$T, size: int) -> [dynamic][dynamic]T {
  tuck_out: [dynamic][dynamic]T = [dynamic][dynamic]T{}
  if (size <= 0) {
      return tuck_out
  }
  tuck_i := 0
  for (tuck_i < seq.len(items)) {
      tuck_piece: [dynamic]T = [dynamic]T{}
      tuck_j := tuck_i
      for ((tuck_j < seq.len(items)) && (tuck_j < (tuck_i + size))) {
          append(&tuck_piece, rt.tuckAt(items, tuck_j))
          tuck_j = (tuck_j + 1)
      }
      append(&tuck_out, tuck_piece)
      tuck_i = (tuck_i + size)
  }
  return tuck_out
}

tuck_Board :: struct {
	cells: [4]int,
}

tuck_checkAccess :: proc () -> int {
  tuck_b := tuck_Board{cells = [4]int{10, 20, 30, 40}}
  tuck_r0 := tuck_atFixed(tuck_b.cells, 0)
  if !(tuck_r0.status == .Ok) {
      return 1
  }
  if (tuck_r0.value != 10) {
      return 2
  }
  tuck_bad := tuck_atFixed(tuck_b.cells, 99)
  if (tuck_bad.status == .Ok) {
      return 3
  }
  tuck_wrote := tuck_setAtFixed(tuck_b.cells, 1, 99)
  if !(tuck_wrote.status == .Ok) {
      return 4
  }
  tuck_r1 := tuck_atFixed(tuck_wrote.value, 1)
  if !(tuck_r1.status == .Ok) {
      return 5
  }
  if (tuck_r1.value != 99) {
      return 6
  }
  tuck_failedWrite := tuck_setAtFixed(tuck_b.cells, (0 - 1), 5)
  if (tuck_failedWrite.status == .Ok) {
      return 7
  }
  return 0
}

tuck_checkCountAndChunk :: proc () -> int {
  tuck_xs: [dynamic]int = [dynamic]int{1, 2, 2, 3, 2, 4}
  if (tuck_countOf(tuck_xs, 2) != 3) {
      return 10
  }
  if (tuck_countOf(tuck_xs, 9) != 0) {
      return 11
  }
  tuck_parts := rt.tuckSeqCopy(tuck_chunk(tuck_xs, 4))
  if (seq.len(tuck_parts) != 2) {
      return 12
  }
  if ((len(rt.tuckAt(tuck_parts, 0)) != 4) || (len(rt.tuckAt(tuck_parts, 1)) != 2)) {
      return 13
  }
  if ((rt.tuckAt(rt.tuckAt(tuck_parts, 1), 0) != 2) || (rt.tuckAt(rt.tuckAt(tuck_parts, 1), 1) != 4)) {
      return 14
  }
  tuck_empty: [dynamic]int = [dynamic]int{}
  tuck_emptyChunks := rt.tuckSeqCopy(tuck_chunk(tuck_empty, 3))
  if (seq.len(tuck_emptyChunks) != 0) {
      return 15
  }
  return 0
}

tuck_main :: proc () -> int {
  tuck_a := tuck_checkAccess()
  if (tuck_a != 0) {
      return tuck_a
  }
  return tuck_checkCountAndChunk()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
