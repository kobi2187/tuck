## Bench — does VALUE SEMANTICS cost anything?
##
## Tuck's central bet (spec Part 1, §7.1 Tier 1) is that every record is a
## value: copied on assignment, no `ref`, no heap, no aliasing. The obvious
## objection is performance — surely copying a struct beats passing a pointer?
## This bench answers it by holding EVERYTHING else constant and changing only
## `object` to `ref object`, then running the same four shapes both ways.
##
## Why this is the honest comparison: it is the same Nim, the same allocator,
## the same flags, the same workload. The only variable is the semantics. A
## Tuck-vs-C++ or Tuck-vs-Rust benchmark would measure a dozen things at once
## and settle nothing.
##
## WHAT IT MEASURES, and why each shape is here:
##
##   S1 read-param     passing a record to a fn that only reads it. The most
##                     common operation in any program. Note both variants
##                     compile to a POINTER parameter — Nim passes a large
##                     non-var object by hidden reference — so this measures
##                     the refcount traffic `ref` adds, not copying.
##   S2 build-return   constructing a record and returning it. This is where
##                     `ref` must call the allocator and value semantics must
##                     not.
##   S3 iterate        a collection of records, reading one field per element
##                     and then every field. Tests locality: contiguous
##                     records vs an array of pointers.
##   S4 copy-assign    `var b = a`, the copy value semantics is accused of.
##
## HOW TO READ IT: ratio > 1.00 means value semantics is FASTER. Run it at two
## record sizes (see SIZES) — the answer genuinely differs between a record
## that fits in a couple of registers and one that does not.
##
##   nim c -d:release --opt:speed --mm:arc -o:/tmp/bvr benches/bench_value_vs_ref.nim
##   /tmp/bvr
##
## Results on the tree at the time of writing are in benches/SCORES.md.

import std/[monotimes, times, strformat, strutils]

# Two record sizes: one that fits in registers, one that does not. The
# crossover between them is the whole story — see SCORES.md.
type
  SmallVal = object
    f0*, f1*: int
  SmallRef = ref object
    f0*, f1*: int
  BigVal = object
    f: array[32, int]          # 256 bytes
  BigRef = ref object
    f: array[32, int]

proc mkSmallVal(v: int): SmallVal {.noinline.} = SmallVal(f0: v, f1: v)
proc mkSmallRef(v: int): SmallRef {.noinline.} = SmallRef(f0: v, f1: v)
proc mkBigVal(v: int): BigVal {.noinline.} =
  for i in 0 ..< 32: result.f[i] = v
proc mkBigRef(v: int): BigRef {.noinline.} =
  new(result)
  for i in 0 ..< 32: result.f[i] = v

# `.noinline` on the readers matters: inlined, the compiler scalarizes the
# whole record away and both variants measure nothing.
proc readSmallVal(b: SmallVal): int {.noinline.} = b.f0 + b.f1
proc readSmallRef(b: SmallRef): int {.noinline.} = b.f0 + b.f1
proc readBigVal(b: BigVal): int {.noinline.} = b.f[0] + b.f[15] + b.f[31]
proc readBigRef(b: BigRef): int {.noinline.} = b.f[0] + b.f[15] + b.f[31]

var sink = 0

template timed(body: untyped): int64 =
  let t0 = getMonoTime()
  body
  (getMonoTime() - t0).inMicroseconds

const
  PassN = 20_000_000
  MakeN = 5_000_000
  Elems = 200_000
  Reps = 50

proc row(name: string, valUs, refUs: int64) =
  let ratio = refUs.float / valUs.float
  let winner = if ratio > 1.03: "value" elif ratio < 0.97: "ref  " else: "tie  "
  echo &"{name:<22}{valUs:>10}{refUs:>10}{ratio:>9.2f}x  {winner}"

proc main() =
  echo &"{\"shape\":<22}{\"VALUE us\":>10}{\"REF us\":>10}{\"ratio\":>10}  winner"
  echo "-- 16-byte record " & '-'.repeat(42)

  block:
    let a = mkSmallVal(1)
    let b = mkSmallRef(1)
    row("S1 read-param",
        timed((for i in 0 ..< PassN: sink += readSmallVal(a))),
        timed((for i in 0 ..< PassN: sink += readSmallRef(b))))
    row("S2 build-return",
        timed((for i in 0 ..< MakeN: sink += mkSmallVal(i).f0)),
        timed((for i in 0 ..< MakeN: sink += mkSmallRef(i).f0)))
    var xv: seq[SmallVal]
    var xr: seq[SmallRef]
    for i in 0 ..< Elems: xv.add mkSmallVal(i); xr.add mkSmallRef(i)
    row("S3 iterate",
        timed((for r in 0 ..< Reps: (for x in xv: sink += x.f0))),
        timed((for r in 0 ..< Reps: (for x in xr: sink += x.f0))))
    row("S4 copy-assign",
        timed((for i in 0 ..< MakeN: (var c = a; c.f0 = i; sink += c.f0))),
        timed((for i in 0 ..< MakeN: (var c = b; c.f0 = i; sink += c.f0))))

  echo "-- 256-byte record " & '-'.repeat(41)

  block:
    let a = mkBigVal(1)
    let b = mkBigRef(1)
    row("S1 read-param",
        timed((for i in 0 ..< PassN: sink += readBigVal(a))),
        timed((for i in 0 ..< PassN: sink += readBigRef(b))))
    row("S2 build-return",
        timed((for i in 0 ..< MakeN: sink += mkBigVal(i).f[0])),
        timed((for i in 0 ..< MakeN: sink += mkBigRef(i).f[0])))
    var xv: seq[BigVal]
    var xr: seq[BigRef]
    for i in 0 ..< Elems: xv.add mkBigVal(i); xr.add mkBigRef(i)
    row("S3 iterate 1 field",
        timed((for r in 0 ..< Reps: (for x in xv: sink += x.f[0]))),
        timed((for r in 0 ..< Reps: (for x in xr: sink += x.f[0]))))
    row("S3 iterate all",
        timed((for r in 0 ..< Reps: (for x in xv: (for i in 0 ..< 32: sink += x.f[i])))),
        timed((for r in 0 ..< Reps: (for x in xr: (for i in 0 ..< 32: sink += x.f[i])))))
    row("S4 copy-assign",
        timed((for i in 0 ..< MakeN: (var c = a; c.f[0] = i; sink += c.f[0]))),
        timed((for i in 0 ..< MakeN: (var c = b; c.f[0] = i; sink += c.f[0]))))

  if sink == 12345: echo "unreachable, keeps the work live"

main()
