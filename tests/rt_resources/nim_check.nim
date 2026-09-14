## The registry's SEMANTICS, asserted against the Nim runtime directly
## (tests/suites/resources_rt.nim compiles and runs this).
##
## Directly rather than through a Tuck program because there is no Tuck-level
## acquire surface yet (docs/resources.md §2) — and these are the rules §7.4
## is actually made of, so leaving them unpinned until that surface exists
## would mean the whole registry ships unverified. Its Odin and D twins assert
## the identical list, which is the point: three runtimes, one behaviour.
import ../../compiler/tuck_rt

var closed: seq[int64]
var flushed: seq[int64]
proc onClose(r: int64) {.nimcall.} = closed.add(r)
proc onFinish(r: int64) {.nimcall.} = flushed.add(r)

var failures = 0
proc check(name: string, cond: bool) =
  if cond:
    echo "  PASS  ", name
  else:
    echo "  FAIL  ", name
    failures.inc

proc main() =
  # --- strict: the mark closes ---------------------------------------------
  var files: ResourceTable
  initResourceTable(files, "file", 8, rtStrict, 0)
  setResourceHooks(files, onFinish, onClose)
  let h1 = acquire(files, 100'i64, "a.tuck:3")
  check "acquire succeeds", h1.status == tsOk
  check "deref reaches the OS handle", deref(files, h1.value) == 100'i64
  check "an unfinished entry is open", files.openCount == 1
  finish(files, h1.value)
  check "strict: on_finish ran at the mark", flushed == @[100'i64]
  check "strict: the handle closed at the mark", closed == @[100'i64]
  check "strict: nothing is left open", files.openCount == 0

  # --- lazy: the mark flushes, the watermark reclaims ----------------------
  closed = @[]; flushed = @[]
  var net: ResourceTable
  initResourceTable(net, "net", 4, rtLazy, 0)
  setResourceHooks(net, onFinish, onClose)
  var hs: seq[ResourceHandle]
  for i in 0 ..< 4: hs.add(acquire(net, int64(i), "x").value)
  check "a capped table fills to its cap", net.openCount == 4
  check "...and then reports absence, not an error",
        acquire(net, 99'i64, "x").status == tsAbsent
  finish(net, hs[0])
  check "lazy: on_finish ran at the mark", flushed == @[0'i64]
  check "lazy: but nothing closed yet (1 of 4 is under the watermark)",
        closed.len == 0
  finish(net, hs[1])
  finish(net, hs[2])
  check "lazy: the ~75% watermark (3 of 4) swept INLINE, inside the mark",
        closed.len == 3

  # --- exit: only close-all closes -----------------------------------------
  closed = @[]; flushed = @[]
  var socks: ResourceTable
  initResourceTable(socks, "sock", 0, rtExit, 0)
  setResourceHooks(socks, onFinish, onClose)
  let a = acquire(socks, 1'i64, "s1").value
  discard acquire(socks, 2'i64, "s2")
  discard acquire(socks, 3'i64, "s3")
  check "an uncapped table grows past any fixed size", socks.entries.len == 3
  finish(socks, a)
  check "exit: the mark closes nothing", closed.len == 0
  closeAll(socks)
  check "exit: close-all runs LIFO in REGISTRATION order",
        closed == @[3'i64, 2'i64, 1'i64]
  check "...and flushes only what was never finished", flushed == @[1'i64, 3'i64, 2'i64]

  # --- the stale handle, which is the whole point --------------------------
  var t2: ResourceTable
  initResourceTable(t2, "k", 2, rtExit, 0)
  let x = acquire(t2, 7'i64, "q").value
  finish(t2, x)
  check "the generation moves on AT THE MARK, so the handle dies there",
        t2.entries[int(x.slot)].gen != x.gen

  # --- a literal-built table behaves as an initialised one -----------------
  # This is what lets every backend emit the declaration as a static
  # initializer with no start-up code: the runtime sizes a capped table on
  # its first acquire.
  var lit = ResourceTable(kind: "lit", cap: 2, policy: rtExit, sweepBatch: 0)
  check "a table built as a plain literal sizes itself on first acquire",
        acquire(lit, 5'i64, "l").status == tsOk
  check "...and still honours its cap",
        acquire(lit, 6'i64, "l").status == tsOk and
        acquire(lit, 7'i64, "l").status == tsAbsent

  # --- the report ----------------------------------------------------------
  var rep: ResourceTable
  initResourceTable(rep, "file", 4, rtExit, 0)
  let k1 = acquire(rep, 1'i64, "main.tuck:4").value
  discard acquire(rep, 2'i64, "main.tuck:9")
  finish(rep, k1)
  var sites: seq[string]
  for e in rep.openEntries(): sites.add(e.site)
  check "the report lists only what was never finished, with its site",
        sites == @["main.tuck:9"]

  if failures > 0: quit(1)

main()
