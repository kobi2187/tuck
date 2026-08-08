## tests/runner.nim — builds tuck, then runs every suite.
##
## THE PIPELINE, and why it is this shape: nim builds tuck ONCE, then tuck
## builds the examples, then the tests run against that one binary. Nim is
## invoked exactly once in the whole suite (twice counting this runner).
##
## It used to be invoked ten times. Every test was a Nim program that did
## `import ../compiler/codegen` — linking the compiler in to call it as a
## library — so `nim c` re-ran semantic analysis over the entire compiler once
## per test file before a single assertion executed.
##
## Then it was bash: run-all-tests.sh drove 30 tests/*.sh, each sourcing
## tests/lib.sh. This is that, in Nim — same assertions, same output, one
## work pool instead of nested xargs.
##
## ONE FLAT POOL. The bash suite had two levels of parallelism: the runner ran
## $(nproc) scripts at once, and each script fanned its own builds out over
## TEST_JOBS. Tuning that was a running battle — 21 scripts x 2 jobs on 6 cores
## measured a 3.2x contention tax, because neither level could see the other.
## Here every subprocess in the whole suite goes into one pool bounded by the
## core count, so the bound is actually the bound.
##
## Usage:
##   tests/run                  every suite
##   tests/run loop_var_type    one suite (repeatable)
##   tests/run --quick          the check-only suites, no build/run/odin
##   tests/run --bless          rewrite goldens (was TUCK_BLESS=1)
##   tests/run --jobs:N         override the pool bound

import std/[os, osproc, strutils, strformat, times, monotimes, streams, sequtils,
            tables]
import harness
import suites/all

proc runPool(items: var seq[WorkItem], argvOf: proc (i: int): seq[string],
             jobs: int, prepOf: proc (i: int) = nil) =
  ## Execute every work item, at most `jobs` at a time, respecting `dep`.
  ##
  ## Dependencies only ever go build -> run (nothing nests deeper), so a
  ## ready-set loop covers it: an item is ready when it has no dep, or its dep
  ## has finished successfully. A dep that FAILED marks the dependent done with
  ## its failure inherited — `runs` reports that as "build failed", which is
  ## what lib.sh did by checking _build's status before running.
  var running: seq[tuple[p: Process, idx: int]]
  var pending = items.len

  template ready(i: int): bool =
    (not items[i].done) and
      (items[i].dep < 0 or
       (items[items[i].dep].done and items[items[i].dep].rc == 0))

  template blocked(i: int): bool =
    items[i].dep >= 0 and items[items[i].dep].done and
      items[items[i].dep].rc != 0

  while pending > 0:
    # Anything whose dependency failed can never run.
    for i in 0 ..< items.len:
      if not items[i].done and blocked(i):
        items[i].done = true
        items[i].rc = 127
        items[i].output = "dependency failed"
        pending.dec

    # Fill the pool.
    var launched = true
    while running.len < jobs and launched:
      launched = false
      for i in 0 ..< items.len:
        if running.len >= jobs: break
        if not ready(i): continue
        if running.anyIt(it.idx == i): continue
        let argv = argvOf(i)
        if argv.len == 0: continue
        # Staging, for the items that need files put in place between their
        # dependency finishing and this command starting.
        if prepOf != nil: prepOf(i)
        try:
          let p = startProcess(argv[0], args = argv[1 .. ^1],
                               options = {poUsePath, poStdErrToStdOut})
          running.add (p, i)
          launched = true
        except OSError as e:
          items[i].done = true
          items[i].rc = 127
          items[i].output = e.msg
          pending.dec
          launched = true

    if running.len == 0:
      # Nothing runnable and nothing running: whatever is left is unreachable.
      for i in 0 ..< items.len:
        if not items[i].done:
          items[i].done = true
          items[i].rc = 127
          items[i].output = "never ran"
          pending.dec
      break

    # Wait for one to finish. Output is drained as it exits rather than in
    # registration order, so a child that fills the 64K pipe buffer cannot
    # wedge the pool behind an earlier one nobody is reading yet.
    var reaped = -1
    while reaped < 0:
      for k, r in running:
        if not r.p.running:
          reaped = k
          break
      if reaped < 0: sleep(2)
    let (p, idx) = running[reaped]
    items[idx].output = p.outputStream.readAll()
    items[idx].rc = p.waitForExit()
    items[idx].done = true
    p.close()
    running.delete(reaped)
    pending.dec

proc runSuites(names: seq[string], jobs: int, bless: bool, root: string): int =
  ## Collect pass over every suite, one pool, then the report pass.
  var ts: seq[T]
  let scratch = getTempDir() / &"tuckt{getCurrentProcessId()}"
  createDir(scratch)
  defer: removeDir(scratch)

  for n in names:
    var t = T(name: n, phase: pCollect, dir: scratch / n, bless: bless,
              root: root)
    createDir(t.dir)
    suiteBody(n)(t)
    ts.add t

  # One pool over every suite's work. Each suite numbered its items from 0, so
  # concatenating them means re-basing every `dep` onto the flat array.
  var flat: seq[WorkItem]
  var owner: seq[tuple[s, i: int]]
  for si in 0 ..< ts.len:
    let base = flat.len
    for ii in 0 ..< ts[si].work.len:
      var w = ts[si].work[ii]
      if w.dep >= 0: w.dep = base + w.dep
      flat.add w
      owner.add (si, ii)

  let argvOf = proc (i: int): seq[string] =
    let (si, ii) = owner[i]
    ts[si].cmdFor(ii)
  let prepOf = proc (i: int) =
    let (si, ii) = owner[i]
    if ii in ts[si].preps: ts[si].preps[ii](ts[si].work[ii].dir)
  runPool(flat, argvOf, jobs, prepOf)

  # Hand results back to their suites, then report.
  for i in 0 ..< flat.len:
    let (si, ii) = owner[i]
    ts[si].work[ii] = flat[i]

  var failures = 0
  for si in 0 ..< ts.len:
    # The report pass replays the body from the top, so the snippet counter
    # must rewind with it — otherwise `src` names t7 where collect named t1
    # and every lookup misses.
    ts[si].rewind()
    ts[si].phase = pReport
    echo &"-- {ts[si].name}"
    suiteBody(ts[si].name)(ts[si])
    if ts[si].failed > 0: failures.inc
  failures

proc secs(t0: MonoTime): string =
  &"{(getMonoTime() - t0).inMilliseconds.float / 1000.0:.1f}"

when isMainModule:
  var
    want: seq[string]
    jobs = countProcessors()
    bless = false
    quick = false
  for a in commandLineParams():
    if a == "--quick": quick = true
    elif a == "--bless": bless = true
    elif a.startsWith("--jobs:"): jobs = parseInt(a[7 .. ^1])
    elif a.startsWith("--"): quit "unknown flag: " & a
    else: want.add a

  let root = getCurrentDir()
  let t0 = getMonoTime()

  # Stage 1 — nim builds tuck. Once.
  echo "== stage 1: nim builds tuck =="
  var ts1 = getMonoTime()
  if execCmd("nim c --hints:off --warnings:off -o:tuck tuck.nim") != 0:
    quit "FAIL: cannot build tuck", 1
  let nimSecs = secs(ts1)
  echo &"  {nimSecs}s, tuck binary {getFileSize(\"tuck\") div 1024}K"

  # Stage 2 — tuck emits .odin for every example. tests/odin_backend checks
  # emitted Odin that it does not itself produce, so generate it here or that
  # suite reports phantom failures for files that were never written.
  #
  # `tuck c`, NOT `tuck build`: all this stage owes odin_backend is the emitted
  # .odin. `build` additionally links a Nim binary per example, which nothing
  # here reads.
  var nTuck = 0
  for f in walkFiles("examples/*.tuck"): nTuck.inc
  var emitSecs = "0.0"
  if not quick:
    echo &"== stage 2: tuck builds {nTuck} examples -> .odin =="
    ts1 = getMonoTime()
    var cmds: seq[seq[string]]
    for f in walkFiles("examples/*.tuck"):
      cmds.add @["./tuck", "c", f, "--odin", "--root:" & root]
    var work: seq[WorkItem]
    for c in cmds: work.add WorkItem(dep: -1)
    runPool(work, proc (i: int): seq[string] = cmds[i], jobs)
    var nOdin = 0
    for f in walkFiles("examples/*.odin"): nOdin.inc
    emitSecs = secs(ts1)
    echo &"  -> {emitSecs}s, {nOdin}/{nTuck} emitted"

  # Stage 3 — the suites.
  let names = if want.len > 0: want
              elif quick: quickSuites()
              else: allSuites()
  echo &"== stage 3: tests ({names.len} suites, pool of {jobs}) =="
  ts1 = getMonoTime()
  let failures = runSuites(names, jobs, bless, root)
  let testSecs = secs(ts1)

  echo ""
  echo "--- timings ---"
  echo &"  {\"nim -> tuck\":<22} {nimSecs:>6}s"
  echo &"  {\"tuck -> odin\":<22} {emitSecs:>6}s"
  echo &"  {\"tests\":<22} {testSecs:>6}s"
  echo &"  {\"total\":<22} {secs(t0):>6}s"

  if failures > 0:
    echo &"{failures} failure(s)."
    quit 1
  echo "All tests passed."
