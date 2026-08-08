## Helpers for tests/suites/cli_smoke.nim.
##
## cli_smoke is the one suite that does not fit the assertion DSL. Its cases
## are SEQUENCES — write a .tuck, build it, run the binary, grep what it
## printed, then do it again with a different source — where each step needs
## the one before. The DSL's collect/report split is for assertions whose work
## is independent; expressing a hundred sequential dependencies as pool edges
## would obscure this rather than parallelize it.
##
## So the cases stay imperative, exactly as the bash was, and these are the
## idioms they repeat. A failing check raises SmokeFail, which cli_smoke's
## runner catches per case — that is `set -e` plus `exit 1` inside a subshell,
## which is how the bash reported a failing case without killing the rest.

import std/[os, osproc, strutils, locks]
import ../harness

type SmokeFail* = object of CatchableError

type Work* = object
  ## One case to run. `body` is a plain `{.nimcall.}` proc, NOT a closure:
  ## a closure allocated on the main thread, run on a worker and destroyed
  ## back on the main thread crosses ORC's thread-local heap and segfaults in
  ## cycle collection. The nine example cases need arguments, so they carry
  ## them as DATA here and `body` reads them, rather than capturing.
  name*: string
  body*: proc (w: Work) {.nimcall, gcsafe.}
  src*, binary*: string
  want*: int

proc fail*(msg: string) {.noreturn.} =
  raise newException(SmokeFail, msg)

proc caseDir*(name: string): string =
  ## Each case gets its own tests/.smoke_<name>, as in the bash. Named rather
  ## than mktemp so a failure leaves the tree behind to look at.
  result = "tests/.smoke_" & name
  removeDir(result)
  createDir(result)

proc write*(dir, fname, code: string): string =
  ## Write a .tuck source into the case directory, returning its path.
  result = dir / fname
  writeFile(result, code)

proc build*(src, outDir: string): tuple[rc: int, output: string] =
  sh(@["./tuck", "build", src, "-o:" & outDir, "--root:" & getCurrentDir()])

proc buildOk*(src, outDir: string) =
  let (rc, outp) = build(src, outDir)
  if rc != 0: fail "build failed for " & src & ": " & outp.strip()

proc compileTo*(src, outDir: string): tuple[rc: int, output: string] =
  sh(@["./tuck", "c", src, "-o:" & outDir, "--root:" & getCurrentDir()])

proc check*(src: string): tuple[rc: int, output: string] =
  sh(@["./tuck", "ch", src, "--root:" & getCurrentDir()])

proc exec*(binary: string): tuple[rc: int, output: string] =
  if not fileExists(binary): fail "no binary at " & binary
  sh(@[binary])

proc mustExit*(binary: string, want: int) =
  let (rc, outp) = exec(binary)
  if rc != want:
    fail binary.lastPathPart & " exited " & $rc & ", want " & $want &
         ": " & outp.strip()

proc mustAbort*(binary, needle: string) =
  ## The binary must FAIL, and say why. Two halves of one assertion: an abort
  ## with the wrong message is as much a regression as no abort at all.
  let (rc, outp) = exec(binary)
  if rc == 0: fail binary.lastPathPart & " did not abort"
  if needle.len > 0 and not outp.contains(needle):
    fail binary.lastPathPart & " aborted without /" & needle & "/: " & outp.strip()

proc mustContain*(path, needle: string) =
  if not fileExists(path): fail "no file at " & path
  if not readFile(path).contains(needle):
    fail path.lastPathPart & " lacks /" & needle & "/"

proc mustNotContain*(path, needle: string) =
  if not fileExists(path): fail "no file at " & path
  if readFile(path).contains(needle):
    fail path.lastPathPart & " contains /" & needle & "/ but should not"

# --- parallel case execution ----------------------------------------------
#
# Every case here spends ~1.05s per `tuck build`, which is `nim c` compiling
# and linking — 31 of them, and serially that was 36.6s while five cores sat
# idle. The cases share nothing writable (each owns tests/.smoke_<name>) and
# the bash ran them as background jobs, so overlapping them is what the
# structure already allowed. Measured 3x on this box.

type Shared = object
  work: seq[Work]
  at, failed: int
  lock: Lock

proc worker(sh: ptr Shared) {.thread.} =
  ## Pull the next case off the queue until it is empty. A ptr to the caller's
  ## stack object rather than globals: `{.thread.}` procs may not touch GC'ed
  ## globals, and threading the state through explicitly says who owns it.
  while true:
    acquire sh.lock
    if sh.at >= sh.work.len:
      release sh.lock
      break
    let item = sh.work[sh.at]
    sh.at.inc
    release sh.lock
    try:
      item.body(item)
    except SmokeFail as e:
      acquire sh.lock
      echo "FAIL: " & item.name & ": " & e.msg
      sh.failed.inc
      release sh.lock

proc runParallel*(work: seq[Work]): int =
  ## Run every case, at most one per core, and return the failure count.
  assert work.len > 0
  var sh = Shared(work: work)
  initLock sh.lock
  let n = min(countProcessors(), work.len)
  var threads = newSeq[Thread[ptr Shared]](n)
  for t in threads.mitems: createThread(t, worker, addr sh)
  joinThreads threads
  deinitLock sh.lock
  sh.failed
