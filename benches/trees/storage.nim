# The storage under a slab: contiguous-by-doubling vs chunks.
# One node array SHARED by every tree (the candidate that avoids merging),
# grown by append; then walked as a tree and read in a scattered order.
#   nim c -d:release --mm:orc storage.nim && ./storage seq 22 && ./storage chunk 22
import std/[monotimes, times, strutils, os]

type Node = object
  kind, v, l, r: int32          # 16 bytes

const Shift = 12                 # 4096 cells = 64 KiB per chunk
const K = 1 shl Shift
const Mask = K - 1

type
  SeqStore = object
    cells: seq[Node]
  ChunkStore = object
    chunks: seq[ptr UncheckedArray[Node]]
    len: int

var worstNs: int64 = 0           # longest single append

proc add(s: var SeqStore, n: Node): int32 {.inline.} =
  if s.cells.len == s.cells.capacity:          # this append reallocates
    let t0 = getMonoTime()
    s.cells.add n
    worstNs = max(worstNs, (getMonoTime() - t0).inNanoseconds)
  else:
    s.cells.add n
  int32(s.cells.len - 1)

proc `[]`(s: SeqStore, i: int32): lent Node {.inline.} = s.cells[i]

proc add(s: var ChunkStore, n: Node): int32 {.inline.} =
  if (s.len and Mask) == 0:                    # this append opens a chunk
    let t0 = getMonoTime()
    s.chunks.add cast[ptr UncheckedArray[Node]](allocShared(K * sizeof(Node)))
    worstNs = max(worstNs, (getMonoTime() - t0).inNanoseconds)
  s.chunks[s.len shr Shift][s.len and Mask] = n
  inc s.len
  int32(s.len - 1)

proc `[]`(s: ChunkStore, i: int32): lent Node {.inline.} =
  s.chunks[i shr Shift][i and Mask]

proc build[S](s: var S, d: int): int32 =
  if d == 0: return s.add Node(kind: 0, v: 1)
  let l = build(s, d - 1)
  let r = build(s, d - 1)
  s.add Node(kind: 1, l: l, r: r)

proc eval[S](s: S, i: int32): int =
  let n = s[i]
  if n.kind == 0: n.v.int else: eval(s, n.l) + eval(s, n.r)

proc scattered[S](s: S, count: int): int =
  ## Reads in a scrambled order: the indirection's cost with no locality.
  var i = 1'u64
  let n = count.uint64
  for _ in 0 ..< count:
    i = (i * 6364136223846793005'u64 + 1442695040888963407'u64)
    result += s[int32(i mod n)].v.int

proc peakRssMb(): float =
  for line in lines("/proc/self/status"):
    if line.startsWith("VmHWM:"):
      return parseFloat(line.splitWhitespace()[1]) / 1024.0

template ms(body: untyped): float =
  let t0 = getMonoTime()
  body
  (getMonoTime() - t0).inNanoseconds.float / 1e6

proc run[S](s: var S, d: int, name: string) =
  var root: int32
  let b = ms: root = build(s, d)
  var total = 0
  let e = ms:
    for _ in 1..10: total += eval(s, root)
  let count = (1 shl (d + 1)) - 1
  let r = ms: total += scattered(s, count)
  echo name.alignLeft(6), " depth ", d, " nodes ", count,
       "  build ", b.formatFloat(ffDecimal, 1).align(7), " ms",
       "  worst append ", (worstNs.float / 1e6).formatFloat(ffDecimal, 2).align(7), " ms",
       "  eval x10 ", e.formatFloat(ffDecimal, 1).align(7), " ms",
       "  scattered ", r.formatFloat(ffDecimal, 1).align(7), " ms",
       "  peak RSS ", peakRssMb().formatFloat(ffDecimal, 0).align(5), " MB",
       "  (", total mod 7, ")"

let which = paramStr(1)
let d = parseInt(paramStr(2))
if which == "seq":
  var s: SeqStore
  run(s, d, "seq")
else:
  var s: ChunkStore
  run(s, d, "chunk")
