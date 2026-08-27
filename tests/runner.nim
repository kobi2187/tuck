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
## MODES. The clock is decided by one question: does an assertion invoke a
## BACKEND compiler? `tuck` is milliseconds; `nim c` / `odin build` on the
## emitted code is ~1s, three orders of magnitude more. So the modes filter by
## VERB — how far down the pipeline each assertion goes — and every suite runs
## in every mode. Assertions above the cap report SKIP and are counted.
##
##   --check   tuck ch only ......... types, effects, diagnostics    ~2s
##   --quick   + tuck c ............. adds emits/omits/frozen        ~5s
##   (default) + nim build & run .... adds exit codes and output     ~30s
##
## `--full` is the default spelled out. The Odin layer additionally needs
## TUCK_REQUIRE_ODIN=1, or it skips when the toolchain is absent.
##
## This replaced a SUITE-level `--quick`, which excluded whole files and so
## classified `declarations` — 27 badChecks, zero runs, ~2ms each — as slow.
##
## Usage:
##   tests/run                  every suite, every assertion
##   tests/run loop_var_type    one suite (repeatable)
##   tests/run --check          the edit-loop gate
##   tests/run --quick          + codegen text and goldens
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

  # Items the MODE excluded (harness.maxVerb) never run. Retire them before
  # the loop so nothing waits on them and nothing marks them failed: their
  # assertions read `skipped` and report SKIP. rc stays 0 — a skipped item is
  # not a failed one, and a dependent build/run is skipped in its own right.
  for i in 0 ..< items.len:
    if items[i].skipped:
      items[i].done = true
      items[i].output = "skipped: mode excludes this verb"
      pending.dec

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

var totalSkipped* = 0
  ## Assertions the mode excluded, summed across suites — reported at the end
  ## so a `--check` green is never mistaken for a full green.

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
    # An empty argv tells runPool there is nothing to launch. A skipped item
    # stays in the array so every index and `dep` edge keeps its meaning
    # across the two passes — only its execution is dropped.
    if flat[i].skipped: return @[]
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
    totalSkipped += ts[si].skipped
  failures

proc secs(t0: MonoTime): string =
  &"{(getMonoTime() - t0).inMilliseconds.float / 1000.0:.1f}"

proc tuckIsStale(): bool =
  ## Is ./tuck older than any source it is built from?
  ##
  ## Exact rather than approximate: the binary comes from tuck.nim, lexer.nim
  ## and compiler/*.nim, and nothing else reaches it. A missing binary is
  ## stale by definition.
  if not fileExists("tuck"): return true
  let built = getLastModificationTime("tuck")
  for f in ["tuck.nim", "lexer.nim"]:
    if fileExists(f) and getLastModificationTime(f) > built: return true
  for f in walkFiles("compiler/*.nim"):
    if getLastModificationTime(f) > built: return true
  false

when isMainModule:
  var
    want: seq[string]
    jobs = countProcessors()
    bless = false
    modeName = "full"
  for a in commandLineParams():
    # MODES filter the work pool by VERB, not by suite. Every suite runs in
    # every mode; assertions needing a backend compile report SKIP when the
    # mode excludes them. See harness.maxVerb for why the verb is the right
    # axis: `tuck` is milliseconds, `nim c`/`odin build` is ~1s, so the only
    # question that moves the clock is whether a backend gets invoked.
    if a == "--check":
      maxVerb = vCheck        # types + effects only. The edit-loop gate.
      modeName = "check"
    elif a == "--quick":
      maxVerb = vEmitD        # + codegen text: emits/omits/frozen goldens
      modeName = "quick"      #   (Nim, Odin and D emission are all ~ms).
    elif a == "--full":
      maxVerb = vRun          # + nim build/run. Odin builds are gated by
      modeName = "full"       # TUCK_REQUIRE_ODIN in the suite that owns them.
    elif a == "--bless": bless = true
    elif a.startsWith("--jobs:"): jobs = parseInt(a[7 .. ^1])
    elif a.startsWith("--"): quit "unknown flag: " & a
    else: want.add a
  let quick = maxVerb < vBuild   # stage 2 emits .odin only when something reads it

  let root = getCurrentDir()
  let t0 = getMonoTime()

  # Stage 1 — nim builds tuck. Once, and only when a source is newer than the
  # binary.
  #
  # Nim's own incremental check is not free: deciding "nothing changed" across
  # the 33 compiler modules costs ~2.95s, every run. That is most of a
  # `--check` pass (~4.5s) spent proving the compiler is already built. An
  # mtime test answers the same question in microseconds.
  #
  # The dependency set is exact — tuck.nim, lexer.nim and compiler/*.nim are
  # what the binary is built from — so a skip is a fact, not an optimism. Any
  # doubt, delete ./tuck and it rebuilds.
  let mustBuild = tuckIsStale()
  echo(if mustBuild: "== stage 1: nim builds tuck =="
       else: "== stage 1: tuck is current, not rebuilt ==")
  var ts1 = getMonoTime()
  if mustBuild:
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

  # Stage 3 — the suites. EVERY suite, in every mode: the mode decides which
  # ASSERTIONS run, not which files. quickSuites() is kept for callers that
  # still want the old file-level split, but is no longer how --quick works —
  # it classified `declarations` (27 badChecks, zero runs, ~2ms each) as slow
  # and skipped it entirely from the inner loop.
  let names = if want.len > 0: want else: allSuites()
  echo &"== stage 3: tests ({names.len} suites, mode {modeName}, pool of {jobs}) =="
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
  # A partial mode must never print the same words as a full run. "All tests
  # passed" after --check would claim the backends were exercised when no
  # backend ran at all.
  if totalSkipped > 0:
    echo &"Passed in mode {modeName}: {totalSkipped} assertion(s) skipped " &
         "(need a backend build). Run tests/run for those."
  else:
    echo "All tests passed."
