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
## Here every subprocess in the whole suite goes into one pool, so the bound is
## actually the bound. That bound is 1 today — see the `jobs` default below:
## concurrent `odin build` processes ran the machine out of memory, and the
## failure surfaced as an intermittent, wandering test failure rather than as
## an OOM (issue #31).
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
##   tests/run --quiet          suppress PASS/SKIP lines — only FAIL and
##                              the per-suite/final summaries print
##   tests/run --jobs:N         pool bound; nproc by default, Odin builds
##                              further capped by memory (issue #31)

import std/[os, osproc, strutils, strformat, times, monotimes, streams, sequtils,
            tables, strtabs]
import harness
import suites/all

var profile: File
  ## `TUCK_TEST_PROFILE=path`: one line per command — milliseconds, exit code,
  ## argv — so the suite's clock can be read rather than guessed at.
if getEnv("TUCK_TEST_PROFILE").len > 0:
  profile = open(getEnv("TUCK_TEST_PROFILE"), fmWrite)

proc isOdinBuild(argv: seq[string]): bool =
  ## The one kind of command whose concurrency is capped (`odinBudget`).
  ## Issue #31 blamed concurrent `odin build`s for its crashes. Measured
  ## 2026-09-22, the crashes are Odin's threaded checker corrupting its own
  ## heap and they happen at --jobs:1 too (see harness.OdinThreads); the cap
  ## stays, sized by memory, because an Odin build is still the heaviest
  ## thing the suite runs (412 MB peak).
  argv.len > 0 and (argv[0].extractFilename == "odin" or
    (argv.len > 1 and argv[1] in ["build", "b"] and "--odin" in argv))

proc odinBudget(): int =
  ## How many `odin build`s may run at once: one per GiB of available memory.
  ##
  ## Measured 2026-09-22 over recursive_types, value_semantics, known_bugs,
  ## memory and resources: the largest build peaked at 412 MB. A GiB each is
  ## 2.5x that. Issue #31 was concurrent Odin builds running LLVM out of
  ## memory, so this is sized from memory rather than from cores — on a small
  ## box it degrades to one at a time, which is what fixed #31.
  result = 1
  try:
    for line in lines("/proc/meminfo"):
      if line.startsWith("MemAvailable:"):
        let kb = parseInt(line.splitWhitespace()[1])
        result = max(1, kb div (1024 * 1024))
  except IOError, ValueError: discard

proc slotEnv(slot: int): StringTableRef =
  ## The environment for pool slot `slot`: the caller's, plus a Nim cache of
  ## this slot's own.
  ##
  ## THE CACHE IS THE WHOLE COST OF A NIM BUILD. Every `tuck build` compiles
  ## the same runtime (tuck_rt, tuck_async, tuck_coro, minicoro) and the same
  ## Nim system modules; only `t.nim` differs. Uncached that is ~1.1s a build
  ## and was 218s of a 330s suite. The bash suite shared one cache per script
  ## via TUCK_NIMCACHE, and the port to Nim dropped it.
  ##
  ## ONE PER SLOT, never one per pool: a slot runs one command at a time, so
  ## its cache is never written by two builds at once, which is the collision
  ## tuck.nim's comment on TUCK_NIMCACHE describes.
  result = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): result[k] = v
  result["TUCK_NIMCACHE"] = getTempDir() / &"tuck-nimcache-{getCurrentProcessId()}" /
                            $slot
  result["TUCK_ODIN_EXTRA"] = OdinThreads   # `tuck build --odin` too

proc outFile(slot: int): string =
  getTempDir() / &"tuck-pool-{getCurrentProcessId()}-{slot}.out"

proc launch(argv: seq[string], env: StringTableRef, outPath: string): Process =
  ## Start `argv` with stdout+stderr going to a FILE, not a pipe.
  ##
  ## A pipe has a 64 KiB kernel buffer, and a child that fills it blocks in
  ## `write()` until someone reads. So a pool on pipes must read each child
  ## to EOF — which blocks on whichever child it picked, so one slow `odin
  ## build` at the head held every finished job behind it and idled the other
  ## slots. (Polling a pipe-backed child for its exit instead is the deadlock:
  ## it never exits because nobody drained it; this hung the pool until
  ## 2026-09-12.) A file never fills, so any child can finish and be reaped
  ## in completion order.
  startProcess("/bin/sh", args = @["-c", "out=$1; shift; exec \"$@\" >\"$out\" 2>&1",
                                   "sh", outPath] & argv,
               env = env, options = {poUsePath})

proc runPool(items: var seq[WorkItem], argvOf: proc (i: int): seq[string],
             jobs: int, prepOf: proc (i: int) = nil) =
  ## Execute every work item, at most `jobs` at a time, respecting `dep`.
  ##
  ## Dependencies only ever go build -> run (nothing nests deeper), so a
  ## ready-set loop covers it: an item is ready when it has no dep, or its dep
  ## has finished successfully. A dep that FAILED marks the dependent done with
  ## its failure inherited — `runs` reports that as "build failed".
  ##
  ## `odin build`s are further capped by `odinBudget` (issue #31).
  var running: seq[tuple[p: Process, idx, slot: int, t0: MonoTime]]
  var pending = items.len
  var envs: seq[StringTableRef]
  for slot in 0 ..< jobs: envs.add slotEnv(slot)
  let odinMax = odinBudget()

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

  proc finish(items: var seq[WorkItem], idx, rc: int, output: string,
              pending: var int) =
    items[idx].rc = rc
    items[idx].output = output
    items[idx].done = true
    pending.dec

  var next = 0      # scan start: items are launched roughly in order
  while pending > 0:
    # Anything whose dependency failed can never run.
    for i in 0 ..< items.len:
      if not items[i].done and blocked(i):
        finish(items, i, 127, "dependency failed", pending)

    # FILL every free slot.
    while running.len < jobs:
      let odinBusy = running.countIt(isOdinBuild(argvOf(it.idx))) >= odinMax
      var pick = -1
      for i in next ..< items.len:
        if not ready(i) or running.anyIt(it.idx == i): continue
        let argv = argvOf(i)
        if argv.len == 0: continue
        if odinBusy and isOdinBuild(argv): continue
        pick = i
        break
      if pick < 0: break
      var slot = 0
      while running.anyIt(it.slot == slot): slot.inc
      # Staging, for the items that need files put in place between their
      # dependency finishing and this command starting.
      if prepOf != nil: prepOf(pick)
      try:
        running.add (launch(argvOf(pick), envs[slot], outFile(slot)), pick,
                     slot, getMonoTime())
      except OSError as e:
        finish(items, pick, 127, e.msg, pending)
      # Everything before the first not-yet-done item is settled for good.
      while next < items.len and items[next].done: next.inc

    if running.len == 0:
      # Nothing runnable and nothing running: whatever is left is unreachable.
      for i in 0 ..< items.len:
        if not items[i].done:
          finish(items, i, 127, "never ran", pending)
      break

    # REAP whatever has finished, in completion order.
    var reapedAny = false
    var k = 0
    while k < running.len:
      let r = running[k]
      let rc = r.p.peekExitCode()
      if rc == -1:
        k.inc
        continue
      let output = try: readFile(outFile(r.slot)) except IOError: ""
      if profile != nil:
        profile.writeLine $(getMonoTime() - r.t0).inMilliseconds & "\t" &
                          $rc & "\t" & argvOf(r.idx).join(" ")
        profile.flushFile()
      r.p.close()
      finish(items, r.idx, rc, output, pending)
      running.delete(k)
      reapedAny = true
    if not reapedAny: sleep(2)

  for slot in 0 ..< jobs:
    try: removeFile(outFile(slot)) except OSError: discard

var totalSkipped* = 0
  ## Assertions the mode excluded, summed across suites — reported at the end
  ## so a `--check` green is never mistaken for a full green.

proc runSuites(names: seq[string], jobs: int, bless: bool, root: string): int =
  ## Collect pass over every suite, one pool, then the report pass.
  var ts: seq[T]
  let scratch = getTempDir() / &"tuckt{getCurrentProcessId()}"
  createDir(scratch)
  defer: removeDir(scratch)

  let tc = getMonoTime()
  for n in names:
    var t = T(name: n, phase: pCollect, dir: scratch / n, bless: bless,
              root: root)
    createDir(t.dir)
    let t1 = getMonoTime()
    suiteBody(n)(t)
    let ms = (getMonoTime() - t1).inMilliseconds
    if profile != nil and ms > 500: echo &"  collect {n}: {ms} ms"
    ts.add t
  if profile != nil: echo &"  collect: {(getMonoTime() - tc).inMilliseconds} ms"

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
  let tp = getMonoTime()
  runPool(flat, argvOf, jobs, prepOf)
  if profile != nil:
    echo &"  pool: {(getMonoTime() - tp).inMilliseconds} ms, {flat.len} items"

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
    let t1 = getMonoTime()
    suiteBody(ts[si].name)(ts[si])
    let ms = (getMonoTime() - t1).inMilliseconds
    if profile != nil and ms > 500: echo &"  report {ts[si].name}: {ms} ms"
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
    # PARALLEL AGAIN (2026-09-22), with the cause of #31 fenced off rather
    # than the whole pool serialised: `runPool` caps concurrent `odin build`s
    # by available memory (`odinBudget`). The history below is why that one
    # command class is special.
    #
    # WAS SERIAL (2026-09-18). Concurrent `odin build` processes were
    # exhausting memory: three consecutive full runs failed on three DIFFERENT
    # recursive-type assertions, one of them naming the cause outright —
    # "LLVM ERROR: out of memory / Allocation failed", rc=134. The rc=139 and
    # empty-output failures are the same event with the message lost (134 is
    # abort(), which is how LLVM ends after LLVM ERROR). Each passed when its
    # suite was re-run alone. See issue #31.
    #
    # The pool bound is what moved, not any emitted code: which assertion lost
    # the race depended on scheduling, which is why it looked like a flaky
    # test for so long. Superseded by PARALLEL AGAIN above, which fences off
    # exactly the command that lost the race.
    #
    # MEASURED COST: 5m55s serial against ~4m10s on this machine's core count,
    # so about 1.4x — far less than the core count suggests, because the pool
    # was already contending. A green suite at 1.4x beats a suite that fails
    # somewhere different every third run.
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
    elif a == "--quiet": quietPasses = true
    elif a.startsWith("--jobs:"): jobs = parseInt(a[7 .. ^1])
    elif a.startsWith("--"): quit "unknown flag: " & a
    else: want.add a
  let quick = maxVerb < vBuild   # stage 2 emits .odin only when something reads it

  let root = getCurrentDir()
  let t0 = getMonoTime()
  # The pool's per-slot Nim caches (slotEnv). NOT shared with the `sh()`
  # sequences: smokelib runs those on several threads at once, and one cache
  # under concurrent builds is the collision TUCK_NIMCACHE warns about —
  # clang crashed reading a half-written system.nim.c when it was tried.
  let cacheRoot = getTempDir() / &"tuck-nimcache-{getCurrentProcessId()}"
  putEnv("TUCK_ODIN_EXTRA", OdinThreads)   # for the sh() sequences as well

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
    # Build BESIDE the binary, then rename over it. `nim c -o:tuck` truncates
    # ./tuck in place, and Linux refuses to exec a file open for writing —
    # ETXTBSY, which Nim surfaces as "Permission denied". Any `./tuck` still
    # running from a previous invocation (or a straggler in this one) turned
    # that into a burst of unrelated-looking failures:
    #
    #   FAIL  mutually recursive fns check
    #         Could not find command: './tuck'. OS error: Permission denied
    #
    # Intermittent, ~1 run in 5, and it named whichever assertions happened to
    # be in flight — which is why it read as a flaky TEST rather than a race
    # over the compiler binary. A rename is atomic and leaves the old inode
    # alive for anything still executing it.
    if execCmd("nim c --hints:off --warnings:off -o:tuck.new tuck.nim") != 0:
      quit "FAIL: cannot build tuck", 1
    moveFile("tuck.new", "tuck")
  let nimSecs = secs(ts1)
  echo &"  {nimSecs}s, tuck binary {getFileSize(\"tuck\") div 1024}K"

  # Stage 2 — tuck emits .odin for every example. tests/odin_backend checks
  # emitted Odin that it does not itself produce, so generate it here or that
  # suite reports phantom failures for files that were never written.
  #
  # `tuck c`, NOT `tuck build`: all this stage owes odin_backend is the emitted
  # .odin. `build` additionally links a Nim binary per example, which nothing
  # here reads.
  #
  # Before backends became mutually exclusive targets, `--odin` also emitted
  # `.nim` for free, so this call silently refreshed examples/*.nim too — an
  # undocumented side effect nothing here (or in odin_backend) ever read.
  # That no longer happens, on purpose.
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

  removeDir(cacheRoot)
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
