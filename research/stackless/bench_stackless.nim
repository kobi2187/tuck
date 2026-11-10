## SPIKE — b_await.tuck, b_chain.tuck and benches/bench_async_scale.nim,
## lowered BY HAND into the stackless form issue #216's transform would emit.
## Each section shows the Tuck source it stands for. Names follow the
## compiler's mangling so the output reads like codegen. Run via ./run.sh.
##
## The lowering rules used (README.md has the reasoning):
##   * an [io] call site in a task body is a pause point: the stage ends with
##     a yield, the call runs at the start of the next stage (today's
##     `(tuckYield(); call)`, split at the semicolon).
##   * an [io] fn called from a frame is itself a frame fn (it may reach a
##     park), its call ends the stage, and the caller resumes in the next
##     stage reading the result the callee wrote through `dest`.
##   * a leaf [io] fn that reaches no park (stepIo) stays native.
##   * locals live in the frame only if they cross a stage boundary.

import std/[times, os, strutils]
import sl_rt

proc tuckˑfnˑstepIo(n: int): tuple[v: int] {.inline.} = (v: n)   # native leaf

# --- b_await.tuck -------------------------------------------------------------
# task compute({base: int}) -> {r: int} [io]:
#   let a = {n: base} stepIo      # pause before
#   let b = {n: base} stepIo      # pause before
#   return {r: a.v + b.v}
type ComputeF = object
  hdr: FrameHdr
  base: int
  a: tuple[v: int]                 # crosses s1 -> s2
  slot: ptr Slot[tuple[r: int]]    # where the result goes (a task root)

proc computeS2(env: pointer): Hop {.nimcall.} =
  let f = cast[ptr ComputeF](env)
  let b = tuckˑfnˑstepIo(f.base)   # does not cross: a stage local
  complete(f.slot, (r: f.a.v + b.v))
  let h = returnTo(addr f.hdr)
  frameFree(f)
  h

proc computeS1(env: pointer): Hop {.nimcall.} =
  let f = cast[ptr ComputeF](env)
  f.a = tuckˑfnˑstepIo(f.base)
  yieldTo(addr f.hdr, computeS2)

proc computeS0(env: pointer): Hop {.nimcall.} =
  yieldTo(addr cast[ptr ComputeF](env).hdr, computeS1)

proc spawnCompute(base: int, slot: ptr Slot[tuple[r: int]]) {.inline.} =
  let f = frameAlloc(ComputeF)
  f.hdr.stage = computeS0
  f.base = base
  f.slot = slot
  ready(addr f.hdr)

proc benchAwait(m: int): float =
  # fn main: for i < m: let res = {base: 1} compute; sum += res.r
  let t0 = epochTime()
  var sum = 0
  for i in 0 ..< m:
    var slot: Slot[tuple[r: int]]
    spawnCompute(1, addr slot)
    sum += awaitFromMain(addr slot).r
  result = epochTime() - t0
  doAssert sum == 2 * m

# --- b_chain.tuck -------------------------------------------------------------
# fn mid({n: int}) -> {v: int} [io]:          # a FRAME fn: called from a task
#   let s = {n: n} stepIo
#   return {v: s.v + 1}
# task chain({m: int}) -> {r: int} [io]:
#   var sum = 0
#   for i in 1 .. m:
#     let x = {n: i} mid                      # pause before, then a frame call
#     sum += x.v
#   return {r: sum}
type
  MidF = object
    hdr: FrameHdr
    n: int
    dest: ptr tuple[v: int]
  ChainF = object
    hdr: FrameHdr
    m, sum, i: int
    x: tuple[v: int]                 # written by mid through `dest`
    slot: ptr Slot[tuple[r: int]]

proc midS0(env: pointer): Hop {.nimcall.} =
  # No pause inside: runs straight through and returns to the caller.
  let f = cast[ptr MidF](env)
  let s = tuckˑfnˑstepIo(f.n)
  f.dest[] = (v: s.v + 1)
  let h = returnTo(addr f.hdr)
  frameFree(f)
  h

proc chainHead(env: pointer): Hop {.nimcall.}

proc chainAfterMid(env: pointer): Hop {.nimcall.} =
  let f = cast[ptr ChainF](env)
  f.sum += f.x.v
  inc f.i
  chainHead(env)                     # loop back edge: a direct call (see README)

proc chainCallMid(env: pointer): Hop {.nimcall.} =
  let f = cast[ptr ChainF](env)
  let c = frameAlloc(MidF)
  c.hdr.caller = addr f.hdr
  c.n = f.i
  c.dest = addr f.x
  f.hdr.stage = chainAfterMid
  midS0(c)                           # enter the callee directly: no hop

proc chainHead(env: pointer): Hop {.nimcall.} =
  let f = cast[ptr ChainF](env)
  if f.i > f.m:
    complete(f.slot, (r: f.sum))
    let h = returnTo(addr f.hdr)
    frameFree(f)
    return h
  yieldTo(addr f.hdr, chainCallMid)

proc benchChain(m: int): float =
  let t0 = epochTime()
  var slot: Slot[tuple[r: int]]
  let f = frameAlloc(ChainF)
  f.hdr.stage = chainHead
  f.m = m
  f.i = 1
  f.slot = addr slot
  ready(addr f.hdr)
  let r = awaitFromMain(addr slot).r
  result = epochTime() - t0
  doAssert r == m * (m + 1) div 2 + m, $r

# --- benches/bench_async_scale.nim --------------------------------------------
# N tasks, each yields K times then counts itself done.
type YieldF = object
  hdr: FrameHdr
  k, j: int

var doneCount = 0

proc yieldLoop(env: pointer): Hop {.nimcall.} =
  let f = cast[ptr YieldF](env)
  if f.j >= f.k:
    inc doneCount
    let h = returnTo(addr f.hdr)
    frameFree(f)
    return h
  inc f.j
  yieldTo(addr f.hdr, yieldLoop)

proc benchScale(n, k: int): (float, float) =
  doneCount = 0
  let t0 = epochTime()
  for i in 0 ..< n:
    let f = frameAlloc(YieldF)
    f.hdr.stage = yieldLoop
    f.k = k
    f.j = 0
    ready(addr f.hdr)
  let tSpawn = epochTime() - t0
  let t1 = epochTime()
  runAll()
  let tRun = epochTime() - t1
  doAssert doneCount == n
  (tSpawn, tRun)

proc ns(t: float, ops: int): string = (t * 1e9 / ops.float).formatFloat(ffDecimal, 1) & " ns/op"

when isMainModule:
  let m = 1_000_000
  let tA = benchAwait(m)
  echo "b_await   spawn+await, 2 yields: ", (tA*1000).formatFloat(ffDecimal, 1), " ms  ", ns(tA, m)
  let mc = 10_000_000
  let tC = benchChain(mc)
  echo "b_chain   yield + frame call:    ", (tC*1000).formatFloat(ffDecimal, 1), " ms  ", ns(tC, mc)
  let (n, k) = (10_000, 100)
  let (tS, tR) = benchScale(n, k)
  echo "scale     spawn N=", n, ":          ", ns(tS, n), "   switch: ", ns(tR, n * (k + 1)),
       "  (", (n.float * (k + 1).float / tR / 1e6).formatFloat(ffDecimal, 1), " M switches/sec)"
  let (tS2, _) = benchScale(1_000_000, 1)
  echo "scale     spawn N=1M (pooled):   ", ns(tS2, 1_000_000)
