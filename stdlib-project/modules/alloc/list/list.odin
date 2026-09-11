#+feature dynamic-literals
package main

import "core:os"
import rt "./tuckrt"

tuck_Node :: struct($T: typeid) {
	value: T,
	next: int,
	prev: int,
}

tuck_Chain :: struct($T: typeid) {
	nodes: [dynamic]tuck_Node(T),
	head: int,
	tail: int,
	size: int,
}

tuck_nowhere :: proc () -> int {
  return (0 - 1)
}

tuck_count :: proc (c: tuck_Chain($T)) -> int {
  return c.size
}

tuck_isEmpty :: proc (c: tuck_Chain($T)) -> bool {
  return (c.size == 0)
}

tuckfn_at :: proc (c: tuck_Chain($T), pos: int) -> rt.TuckResult(T) {
  if ((pos < 0) || (pos >= len(c.nodes))) {
      return rt.tnone(T)
  }
  return rt.tok(rt.tuckAt(c.nodes, pos).value)
}

tuck_firstPos :: proc (c: tuck_Chain($T)) -> int {
  return c.head
}

tuck_lastPos :: proc (c: tuck_Chain($T)) -> int {
  return c.tail
}

tuck_nextPos :: proc (c: tuck_Chain($T), pos: int) -> int {
  if ((pos < 0) || (pos >= len(c.nodes))) {
      return tuck_nowhere()
  }
  return rt.tuckAt(c.nodes, pos).next
}

tuck_prevPos :: proc (c: tuck_Chain($T), pos: int) -> int {
  if ((pos < 0) || (pos >= len(c.nodes))) {
      return tuck_nowhere()
  }
  return rt.tuckAt(c.nodes, pos).prev
}

tuck_first :: proc (c: tuck_Chain($T)) -> rt.TuckResult(T) {
  return tuckfn_at(c, c.head)
}

tuck_last :: proc (c: tuck_Chain($T)) -> rt.TuckResult(T) {
  return tuckfn_at(c, c.tail)
}

tuck_linkNext :: proc (ns: [dynamic]tuck_Node($T), pos: int, to: int) -> [dynamic]tuck_Node(T) {
  ns := ns
  ns = rt.tuckSeqCopy(ns)
  return tuck_linkNext_moved(ns, pos, to)
}

tuck_linkNext_moved :: proc (ns: [dynamic]tuck_Node($T), pos: int, to: int) -> [dynamic]tuck_Node(T) {
  if (pos < 0) {
      return ns
  }
  tuck_out := ns
  tuck_n := rt.tuckAt(tuck_out, pos)
  rt.tuckSetAt(tuck_out, pos, tuck_Node(T){value = tuck_n.value, next = to, prev = tuck_n.prev})
  return tuck_out
}

tuck_linkPrev :: proc (ns: [dynamic]tuck_Node($T), pos: int, to: int) -> [dynamic]tuck_Node(T) {
  ns := ns
  ns = rt.tuckSeqCopy(ns)
  return tuck_linkPrev_moved(ns, pos, to)
}

tuck_linkPrev_moved :: proc (ns: [dynamic]tuck_Node($T), pos: int, to: int) -> [dynamic]tuck_Node(T) {
  if (pos < 0) {
      return ns
  }
  tuck_out := ns
  tuck_n := rt.tuckAt(tuck_out, pos)
  rt.tuckSetAt(tuck_out, pos, tuck_Node(T){value = tuck_n.value, next = tuck_n.next, prev = to})
  return tuck_out
}

tuck_append :: proc (c: tuck_Chain($T), value: T) -> tuck_Chain(T) {
  c := c
  c.nodes = rt.tuckSeqCopy(c.nodes)
  return tuck_append_moved(c, value)
}

tuck_append_moved :: proc (c: tuck_Chain($T), value: T) -> tuck_Chain(T) {
  tuck_slot := len(c.nodes)
  tuck_ns := c.nodes
  tuck_fresh := tuck_Node(T){value = value, next = tuck_nowhere(), prev = c.tail}
  append(&tuck_ns, tuck_fresh)
  tuck_ns = tuck_linkNext_moved(tuck_ns, c.tail, tuck_slot)
  tuck_h := ((c.head < 0) ? tuck_slot : c.head)
  return tuck_Chain(T){nodes = tuck_ns, head = tuck_h, tail = tuck_slot, size = (c.size + 1)}
}

tuck_prepend :: proc (c: tuck_Chain($T), value: T) -> tuck_Chain(T) {
  c := c
  c.nodes = rt.tuckSeqCopy(c.nodes)
  return tuck_prepend_moved(c, value)
}

tuck_prepend_moved :: proc (c: tuck_Chain($T), value: T) -> tuck_Chain(T) {
  tuck_slot := len(c.nodes)
  tuck_ns := c.nodes
  tuck_fresh := tuck_Node(T){value = value, next = c.head, prev = tuck_nowhere()}
  append(&tuck_ns, tuck_fresh)
  tuck_ns = tuck_linkPrev_moved(tuck_ns, c.head, tuck_slot)
  tuck_t := ((c.tail < 0) ? tuck_slot : c.tail)
  return tuck_Chain(T){nodes = tuck_ns, head = tuck_slot, tail = tuck_t, size = (c.size + 1)}
}

tuck_insertAfter :: proc (c: tuck_Chain($T), pos: int, value: T) -> tuck_Chain(T) {
  c := c
  c.nodes = rt.tuckSeqCopy(c.nodes)
  return tuck_insertAfter_moved(c, pos, value)
}

tuck_insertAfter_moved :: proc (c: tuck_Chain($T), pos: int, value: T) -> tuck_Chain(T) {
  if ((pos < 0) || (pos >= len(c.nodes))) {
      return c
  }
  tuck_slot := len(c.nodes)
  tuck_after := rt.tuckAt(c.nodes, pos).next
  tuck_ns := c.nodes
  tuck_fresh := tuck_Node(T){value = value, next = tuck_after, prev = pos}
  append(&tuck_ns, tuck_fresh)
  tuck_ns = tuck_linkNext_moved(tuck_ns, pos, tuck_slot)
  tuck_ns = tuck_linkPrev_moved(tuck_ns, tuck_after, tuck_slot)
  tuck_t := ((tuck_after < 0) ? tuck_slot : c.tail)
  return tuck_Chain(T){nodes = tuck_ns, head = c.head, tail = tuck_t, size = (c.size + 1)}
}

tuck_removeAt :: proc (c: tuck_Chain($T), pos: int) -> tuck_Chain(T) {
  c := c
  c.nodes = rt.tuckSeqCopy(c.nodes)
  return tuck_removeAt_moved(c, pos)
}

tuck_removeAt_moved :: proc (c: tuck_Chain($T), pos: int) -> tuck_Chain(T) {
  if ((pos < 0) || (pos >= len(c.nodes))) {
      return c
  }
  tuck_before := rt.tuckAt(c.nodes, pos).prev
  tuck_after := rt.tuckAt(c.nodes, pos).next
  tuck_ns := c.nodes
  tuck_ns = tuck_linkNext_moved(tuck_ns, tuck_before, tuck_after)
  tuck_ns = tuck_linkPrev_moved(tuck_ns, tuck_after, tuck_before)
  tuck_h := ((pos == c.head) ? tuck_after : c.head)
  tuck_t := ((pos == c.tail) ? tuck_before : c.tail)
  return tuck_Chain(T){nodes = tuck_ns, head = tuck_h, tail = tuck_t, size = (c.size - 1)}
}

tuck_toSeq :: proc (c: tuck_Chain($T)) -> [dynamic]T {
  tuck_out: [dynamic]T = [dynamic]T{}
  tuck_pos := c.head
  for (tuck_pos >= 0) {
      append(&tuck_out, rt.tuckAt(c.nodes, tuck_pos).value)
      tuck_pos = rt.tuckAt(c.nodes, tuck_pos).next
  }
  return tuck_out
}

tuckfn_concat :: proc (a: tuck_Chain($T), b: tuck_Chain(T)) -> tuck_Chain(T) {
  a := a
  a.nodes = rt.tuckSeqCopy(a.nodes)
  return tuckfn_concat_moved(a, b)
}

tuckfn_concat_moved :: proc (a: tuck_Chain($T), b: tuck_Chain(T)) -> tuck_Chain(T) {
  tuck_out := a
  tuck_bs := rt.tuckSeqCopy(tuck_toSeq(b))
  for tuck_i in (0 ..= (len(tuck_bs) - 1)) {
      tuck_out = tuck_append_moved(tuck_out, rt.tuckAt(tuck_bs, tuck_i))
  }
  return tuck_out
}

tuck_emptyChain :: proc () -> tuck_Chain(int) {
  return tuck_Chain(int){nodes = [dynamic]tuck_Node(int){}, head = tuck_nowhere(), tail = tuck_nowhere(), size = 0}
}

tuck_oneTwoThree :: proc () -> tuck_Chain(int) {
  tuck_c := tuck_emptyChain()
  tuck_c = tuck_append_moved(tuck_c, 1)
  tuck_c = tuck_append_moved(tuck_c, 2)
  return tuck_append(tuck_c, 3)
}

tuck_checkBuild :: proc () -> int {
  tuck_e := tuck_emptyChain()
  if !tuck_isEmpty(tuck_e) {
      return 1
  }
  tuck_noHead := tuck_first(tuck_e)
  if (tuck_noHead.status == .Ok) {
      return 2
  }
  tuck_c := tuck_oneTwoThree()
  if (tuck_count(tuck_c) != 3) {
      return 3
  }
  tuck_f := tuck_first(tuck_c)
  if !(tuck_f.status == .Ok) {
      return 4
  }
  if (tuck_f.value != 1) {
      return 5
  }
  tuck_l := tuck_last(tuck_c)
  if !(tuck_l.status == .Ok) {
      return 6
  }
  if (tuck_l.value != 3) {
      return 7
  }
  return tuck_checkOrder()
}

tuck_checkOrder :: proc () -> int {
  tuck_xs := rt.tuckSeqCopy(tuck_toSeq(tuck_oneTwoThree()))
  if (len(tuck_xs) != 3) {
      return 8
  }
  if (rt.tuckAt(tuck_xs, 0) != 1) {
      return 9
  }
  if (rt.tuckAt(tuck_xs, 2) != 3) {
      return 10
  }
  tuck_p := tuck_prepend(tuck_oneTwoThree(), 0)
  tuck_ps := rt.tuckSeqCopy(tuck_toSeq(tuck_p))
  if (rt.tuckAt(tuck_ps, 0) != 0) {
      return 11
  }
  if (rt.tuckAt(tuck_ps, 3) != 3) {
      return 12
  }
  return tuck_checkHandles()
}

tuck_checkHandles :: proc () -> int {
  tuck_c := tuck_oneTwoThree()
  tuck_head := tuck_firstPos(tuck_c)
  tuck_second := tuck_nextPos(tuck_c, tuck_head)
  tuck_v := tuckfn_at(tuck_c, tuck_second)
  if !(tuck_v.status == .Ok) {
      return 13
  }
  if (tuck_v.value != 2) {
      return 14
  }
  tuck_ins := tuck_insertAfter(tuck_c, tuck_second, 99)
  tuck_isq := rt.tuckSeqCopy(tuck_toSeq(tuck_ins))
  if (len(tuck_isq) != 4) {
      return 15
  }
  if (rt.tuckAt(tuck_isq, 2) != 99) {
      return 16
  }
  return tuck_checkRemoval()
}

tuck_checkRemoval :: proc () -> int {
  tuck_c := tuck_oneTwoThree()
  tuck_head := tuck_firstPos(tuck_c)
  tuck_second := tuck_nextPos(tuck_c, tuck_head)
  tuck_cut := tuck_removeAt(tuck_c, tuck_second)
  if (tuck_count(tuck_cut) != 2) {
      return 17
  }
  tuck_cs := rt.tuckSeqCopy(tuck_toSeq(tuck_cut))
  if (len(tuck_cs) != 2) {
      return 18
  }
  if (rt.tuckAt(tuck_cs, 0) != 1) {
      return 19
  }
  if (rt.tuckAt(tuck_cs, 1) != 3) {
      return 20
  }
  tuck_head2 := tuck_firstPos(tuck_c)
  tuck_noHead := tuck_removeAt(tuck_c, tuck_head2)
  tuck_hs := rt.tuckSeqCopy(tuck_toSeq(tuck_noHead))
  if (rt.tuckAt(tuck_hs, 0) != 2) {
      return 21
  }
  if (tuck_count(tuck_c) != 3) {
      return 22
  }
  return tuck_checkConcat()
}

tuck_checkConcat :: proc () -> int {
  tuck_joined := tuckfn_concat(tuck_oneTwoThree(), tuck_oneTwoThree())
  if (tuck_count(tuck_joined) != 6) {
      return 23
  }
  tuck_js := rt.tuckSeqCopy(tuck_toSeq(tuck_joined))
  if (len(tuck_js) != 6) {
      return 24
  }
  if (rt.tuckAt(tuck_js, 3) != 1) {
      return 25
  }
  return 0
}

tuck_main :: proc () -> int {
  return tuck_checkBuild()
}

main :: proc() {
	mainRc := tuck_main()
	os.exit(mainRc)
}
