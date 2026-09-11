{.experimental: "codeReordering".}
import ../../../../compiler/tuck_rt
import seq as tuck_mod_seq

proc tuck_nowhere*(): int
proc tuck_count*[T](c: sink tuck_Chain[T]): int
proc tuck_isEmpty*[T](c: sink tuck_Chain[T]): bool
proc tuckfn_at*[T](c: sink tuck_Chain[T], pos: int): TuckResult[T]
proc tuck_firstPos*[T](c: sink tuck_Chain[T]): int
proc tuck_lastPos*[T](c: sink tuck_Chain[T]): int
proc tuck_nextPos*[T](c: sink tuck_Chain[T], pos: int): int
proc tuck_prevPos*[T](c: sink tuck_Chain[T], pos: int): int
proc tuck_first*[T](c: sink tuck_Chain[T]): TuckResult[T]
proc tuck_last*[T](c: sink tuck_Chain[T]): TuckResult[T]
proc tuck_linkNext*[T](ns: sink seq[tuck_Node[T]], pos: int, to: int): seq[tuck_Node[T]]
proc tuck_linkPrev*[T](ns: sink seq[tuck_Node[T]], pos: int, to: int): seq[tuck_Node[T]]
proc tuck_append*[T](c: sink tuck_Chain[T], value: T): tuck_Chain[T]
proc tuck_prepend*[T](c: sink tuck_Chain[T], value: T): tuck_Chain[T]
proc tuck_insertAfter*[T](c: sink tuck_Chain[T], pos: int, value: T): tuck_Chain[T]
proc tuck_removeAt*[T](c: sink tuck_Chain[T], pos: int): tuck_Chain[T]
proc tuck_toSeq*[T](c: tuck_Chain[T]): seq[T]
proc tuckfn_concat*[T](a: sink tuck_Chain[T], b: sink tuck_Chain[T]): tuck_Chain[T]
proc tuck_emptyChain*(): tuck_Chain[int]
proc tuck_oneTwoThree*(): tuck_Chain[int]
proc tuck_checkBuild*(): int
proc tuck_checkOrder*(): int
proc tuck_checkHandles*(): int
proc tuck_checkRemoval*(): int
proc tuck_checkConcat*(): int
proc tuck_main*(): int

type tuck_Node*[T] = object
  value*: T
  next*: int
  prev*: int

type tuck_Chain*[T] = object
  nodes*: seq[tuck_Node[T]]
  head*: int
  tail*: int
  size*: int

proc tuck_nowhere*(): int =
  return (0 - 1)

proc tuck_count*[T](c: sink tuck_Chain[T]): int =
  return c.size

proc tuck_isEmpty*[T](c: sink tuck_Chain[T]): bool =
  return (c.size == 0)

proc tuckfn_at*[T](c: sink tuck_Chain[T], pos: int): TuckResult[T] =
  if ((pos < 0) or (pos >= c.nodes.len)):
    if true:
      return tnone[T]()
  return tok(tuck_rt.tuckAt(c.nodes, pos).value)

proc tuck_firstPos*[T](c: sink tuck_Chain[T]): int =
  return c.head

proc tuck_lastPos*[T](c: sink tuck_Chain[T]): int =
  return c.tail

proc tuck_nextPos*[T](c: sink tuck_Chain[T], pos: int): int =
  if ((pos < 0) or (pos >= c.nodes.len)):
    if true:
      return tuck_nowhere()
  return tuck_rt.tuckAt(c.nodes, pos).next

proc tuck_prevPos*[T](c: sink tuck_Chain[T], pos: int): int =
  if ((pos < 0) or (pos >= c.nodes.len)):
    if true:
      return tuck_nowhere()
  return tuck_rt.tuckAt(c.nodes, pos).prev

proc tuck_first*[T](c: sink tuck_Chain[T]): TuckResult[T] =
  return tuckfn_at(c, c.head)

proc tuck_last*[T](c: sink tuck_Chain[T]): TuckResult[T] =
  return tuckfn_at(c, c.tail)

proc tuck_linkNext*[T](ns: sink seq[tuck_Node[T]], pos: int, to: int): seq[tuck_Node[T]] =
  if (pos < 0):
    if true:
      return ns
  var tuck_out = ns
  var tuck_n = tuck_rt.tuckAt(tuck_out, pos)
  tuck_rt.tuckSetAt(tuck_out, pos, tuck_Node[T](value: tuck_n.value, next: to, prev: tuck_n.prev))
  return tuck_out

proc tuck_linkPrev*[T](ns: sink seq[tuck_Node[T]], pos: int, to: int): seq[tuck_Node[T]] =
  if (pos < 0):
    if true:
      return ns
  var tuck_out = ns
  var tuck_n = tuck_rt.tuckAt(tuck_out, pos)
  tuck_rt.tuckSetAt(tuck_out, pos, tuck_Node[T](value: tuck_n.value, next: tuck_n.next, prev: to))
  return tuck_out

proc tuck_append*[T](c: sink tuck_Chain[T], value: T): tuck_Chain[T] =
  var tuck_slot = c.nodes.len
  var tuck_ns = c.nodes
  var tuck_fresh = tuck_Node[T](value: value, next: tuck_nowhere(), prev: c.tail)
  tuck_ns.add(tuck_fresh)
  tuck_ns = tuck_linkNext(tuck_ns, c.tail, tuck_slot)
  var tuck_h = (if (c.head < 0): tuck_slot else: c.head)
  return tuck_Chain[T](nodes: tuck_ns, head: tuck_h, tail: tuck_slot, size: (c.size + 1))

proc tuck_prepend*[T](c: sink tuck_Chain[T], value: T): tuck_Chain[T] =
  var tuck_slot = c.nodes.len
  var tuck_ns = c.nodes
  var tuck_fresh = tuck_Node[T](value: value, next: c.head, prev: tuck_nowhere())
  tuck_ns.add(tuck_fresh)
  tuck_ns = tuck_linkPrev(tuck_ns, c.head, tuck_slot)
  var tuck_t = (if (c.tail < 0): tuck_slot else: c.tail)
  return tuck_Chain[T](nodes: tuck_ns, head: tuck_slot, tail: tuck_t, size: (c.size + 1))

proc tuck_insertAfter*[T](c: sink tuck_Chain[T], pos: int, value: T): tuck_Chain[T] =
  if ((pos < 0) or (pos >= c.nodes.len)):
    if true:
      return c
  var tuck_slot = c.nodes.len
  var tuck_after = tuck_rt.tuckAt(c.nodes, pos).next
  var tuck_ns = c.nodes
  var tuck_fresh = tuck_Node[T](value: value, next: tuck_after, prev: pos)
  tuck_ns.add(tuck_fresh)
  tuck_ns = tuck_linkNext(tuck_ns, pos, tuck_slot)
  tuck_ns = tuck_linkPrev(tuck_ns, tuck_after, tuck_slot)
  var tuck_t = (if (tuck_after < 0): tuck_slot else: c.tail)
  return tuck_Chain[T](nodes: tuck_ns, head: c.head, tail: tuck_t, size: (c.size + 1))

proc tuck_removeAt*[T](c: sink tuck_Chain[T], pos: int): tuck_Chain[T] =
  if ((pos < 0) or (pos >= c.nodes.len)):
    if true:
      return c
  var tuck_before = tuck_rt.tuckAt(c.nodes, pos).prev
  var tuck_after = tuck_rt.tuckAt(c.nodes, pos).next
  var tuck_ns = c.nodes
  tuck_ns = tuck_linkNext(tuck_ns, tuck_before, tuck_after)
  tuck_ns = tuck_linkPrev(tuck_ns, tuck_after, tuck_before)
  var tuck_h = (if (pos == c.head): tuck_after else: c.head)
  var tuck_t = (if (pos == c.tail): tuck_before else: c.tail)
  return tuck_Chain[T](nodes: tuck_ns, head: tuck_h, tail: tuck_t, size: (c.size - 1))

proc tuck_toSeq*[T](c: tuck_Chain[T]): seq[T] =
  var tuck_out: seq[T] = @[]
  var tuck_pos = c.head
  while (tuck_pos >= 0):
    if true:
      tuck_out.add(tuck_rt.tuckAt(c.nodes, tuck_pos).value)
      tuck_pos = tuck_rt.tuckAt(c.nodes, tuck_pos).next
  return tuck_out

proc tuckfn_concat*[T](a: sink tuck_Chain[T], b: sink tuck_Chain[T]): tuck_Chain[T] =
  var tuck_out = a
  var tuck_bs = tuck_toSeq(b)
  for tuck_i in (0 .. (tuck_bs.len - 1)):
    if true:
      tuck_out = tuck_append(tuck_out, tuck_rt.tuckAt(tuck_bs, tuck_i))
  return tuck_out

proc tuck_emptyChain*(): tuck_Chain[int] =
  return tuck_Chain[int](nodes: @[], head: tuck_nowhere(), tail: tuck_nowhere(), size: 0)

proc tuck_oneTwoThree*(): tuck_Chain[int] =
  var tuck_c = tuck_emptyChain()
  tuck_c = tuck_append(tuck_c, 1)
  tuck_c = tuck_append(tuck_c, 2)
  return tuck_append(tuck_c, 3)

proc tuck_checkBuild*(): int =
  var tuck_e = tuck_emptyChain()
  if not tuck_isEmpty(tuck_e):
    if true:
      return 1
  var tuck_noHead = tuck_first(tuck_e)
  if tuck_noHead.ok:
    if true:
      return 2
  var tuck_c = tuck_oneTwoThree()
  if (tuck_count(tuck_c) != 3):
    if true:
      return 3
  var tuck_f = tuck_first(tuck_c)
  if not tuck_f.ok:
    if true:
      return 4
  if (tuck_f.value != 1):
    if true:
      return 5
  var tuck_l = tuck_last(tuck_c)
  if not tuck_l.ok:
    if true:
      return 6
  if (tuck_l.value != 3):
    if true:
      return 7
  return tuck_checkOrder()

proc tuck_checkOrder*(): int =
  var tuck_xs = tuck_toSeq(tuck_oneTwoThree())
  if (tuck_xs.len != 3):
    if true:
      return 8
  if (tuck_rt.tuckAt(tuck_xs, 0) != 1):
    if true:
      return 9
  if (tuck_rt.tuckAt(tuck_xs, 2) != 3):
    if true:
      return 10
  var tuck_p = tuck_prepend(tuck_oneTwoThree(), 0)
  var tuck_ps = tuck_toSeq(tuck_p)
  if (tuck_rt.tuckAt(tuck_ps, 0) != 0):
    if true:
      return 11
  if (tuck_rt.tuckAt(tuck_ps, 3) != 3):
    if true:
      return 12
  return tuck_checkHandles()

proc tuck_checkHandles*(): int =
  var tuck_c = tuck_oneTwoThree()
  var tuck_head = tuck_firstPos(tuck_c)
  var tuck_second = tuck_nextPos(tuck_c, tuck_head)
  var tuck_v = tuckfn_at(tuck_c, tuck_second)
  if not tuck_v.ok:
    if true:
      return 13
  if (tuck_v.value != 2):
    if true:
      return 14
  var tuck_ins = tuck_insertAfter(tuck_c, tuck_second, 99)
  var tuck_isq = tuck_toSeq(tuck_ins)
  if (tuck_isq.len != 4):
    if true:
      return 15
  if (tuck_rt.tuckAt(tuck_isq, 2) != 99):
    if true:
      return 16
  return tuck_checkRemoval()

proc tuck_checkRemoval*(): int =
  var tuck_c = tuck_oneTwoThree()
  var tuck_head = tuck_firstPos(tuck_c)
  var tuck_second = tuck_nextPos(tuck_c, tuck_head)
  var tuck_cut = tuck_removeAt(tuck_c, tuck_second)
  if (tuck_count(tuck_cut) != 2):
    if true:
      return 17
  var tuck_cs = tuck_toSeq(tuck_cut)
  if (tuck_cs.len != 2):
    if true:
      return 18
  if (tuck_rt.tuckAt(tuck_cs, 0) != 1):
    if true:
      return 19
  if (tuck_rt.tuckAt(tuck_cs, 1) != 3):
    if true:
      return 20
  var tuck_head2 = tuck_firstPos(tuck_c)
  var tuck_noHead = tuck_removeAt(tuck_c, tuck_head2)
  var tuck_hs = tuck_toSeq(tuck_noHead)
  if (tuck_rt.tuckAt(tuck_hs, 0) != 2):
    if true:
      return 21
  if (tuck_count(tuck_c) != 3):
    if true:
      return 22
  return tuck_checkConcat()

proc tuck_checkConcat*(): int =
  var tuck_joined = tuckfn_concat(tuck_oneTwoThree(), tuck_oneTwoThree())
  if (tuck_count(tuck_joined) != 6):
    if true:
      return 23
  var tuck_js = tuck_toSeq(tuck_joined)
  if (tuck_js.len != 6):
    if true:
      return 24
  if (tuck_rt.tuckAt(tuck_js, 3) != 1):
    if true:
      return 25
  return 0

proc tuck_main*(): int =
  return tuck_checkBuild()


when isMainModule:
  quit(tuck_main())
