# Tree representation: per-edge boxing (what lowering_recursive emits today,
# with the sink/lent fixes applied) vs one node array per tree value (what a
# slab lowering would emit). Same workload, hand-written, -d:release.
import std/[monotimes, times, strutils, os]

# --- boxed: each recursive edge is its own one-element seq ------------------
type
  BKind = enum bNum, bAdd
  Boxed = object
    case kind: BKind
    of bNum: v: int
    of bAdd: l, r: seq[Boxed]

proc bAt(s: seq[Boxed]): lent Boxed {.inline.} = s[0]

proc bBuild(d: int): Boxed =
  if d == 0: return Boxed(kind: bNum, v: 1)
  Boxed(kind: bAdd, l: @[bBuild(d - 1)], r: @[bBuild(d - 1)])

proc bEval(e: Boxed): int =
  case e.kind
  of bNum: e.v
  of bAdd: bEval(bAt(e.l)) + bEval(bAt(e.r))

# --- slab: one node array per tree; children are indices --------------------
type
  Node = object
    kind: int32
    v: int32
    l, r: int32
  Tree = object
    nodes: seq[Node]
    root: int32

proc sLeaf(v: int): Tree =
  Tree(nodes: @[Node(kind: 0, v: int32(v))], root: 0)

proc shiftInto(dst: var seq[Node], src: seq[Node]): int32 =
  ## Append src's nodes to dst, renumbering their links. Returns the offset.
  let base = int32(dst.len)
  for n in src:
    var m = n
    if m.kind == 1:
      m.l += base
      m.r += base
    dst.add m
  base

proc sAdd(l, r: sink Tree): Tree =
  ## A construction over two independent subtrees: the SMALLER is appended to
  ## the larger, so building any shape costs O(n log n), never O(n^2).
  var big = l
  var small = r
  let swapped = r.nodes.len > l.nodes.len
  if swapped: swap(big, small)
  result.nodes = move big.nodes
  let base = shiftInto(result.nodes, small.nodes)
  let (li, ri) = if swapped: (small.root + base, big.root)
                 else: (big.root, small.root + base)
  result.nodes.add Node(kind: 1, l: li, r: ri)
  result.root = int32(result.nodes.len - 1)

proc sBuild(d: int): Tree =
  if d == 0: return sLeaf(1)
  sAdd(sBuild(d - 1), sBuild(d - 1))

proc sEvalAt(ns: seq[Node], i: int32): int =
  let n = ns[i]
  if n.kind == 0: n.v.int
  else: sEvalAt(ns, n.l) + sEvalAt(ns, n.r)

proc sEval(t: Tree): int = sEvalAt(t.nodes, t.root)

# --- timing -----------------------------------------------------------------
template ms(body: untyped): float =
  let t0 = getMonoTime()
  body
  (getMonoTime() - t0).inNanoseconds.float / 1e6

let d = parseInt(paramStr(1))
let rounds = 10
var sink0 = 0

var bt: Boxed
let bBuildMs = ms: bt = bBuild(d)
let bEvalMs = ms:
  for i in 1..rounds: sink0 += bEval(bt)
let bCopyMs = ms:
  for i in 1..rounds:
    var c = bt          # a real copy: the edit below keeps it alive
    c.l[0] = Boxed(kind: bNum, v: 2)
    sink0 += bEval(c)

var st: Tree
let sBuildMs = ms: st = sBuild(d)
let sEvalMs = ms:
  for i in 1..rounds: sink0 += sEval(st)
let sCopyMs = ms:
  for i in 1..rounds:
    var c = st
    c.nodes[0].v = 2
    sink0 += sEval(c)

echo "depth ", d, "  nodes ", st.nodes.len, "  (check ", sink0 mod 7, ")"
echo "            build ms   eval x10 ms   copy+eval x10 ms"
echo "boxed    ", bBuildMs.formatFloat(ffDecimal, 1).align(10), bEvalMs.formatFloat(ffDecimal, 1).align(13), bCopyMs.formatFloat(ffDecimal, 1).align(18)
echo "slab     ", sBuildMs.formatFloat(ffDecimal, 1).align(10), sEvalMs.formatFloat(ffDecimal, 1).align(13), sCopyMs.formatFloat(ffDecimal, 1).align(18)
