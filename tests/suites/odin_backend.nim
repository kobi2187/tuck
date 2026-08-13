## End-to-end guard for the Odin backend: every gated example must compile
## with `odin build`, and the ones with a known answer must RUN and produce it.
##
## The run layer is the point. 26-actor-run compiled cleanly for a whole
## session while hanging forever at runtime (actors are daemons, so driving
## the scheduler for them never terminates) — a compile-only check called
## that a pass. Exit codes catch it.
##
## Skips with a notice when Odin is absent, unless TUCK_REQUIRE_ODIN=1, so
## CI can insist the check actually ran rather than silently vanishing.
##
## Was a Nim program, but imported nothing from the compiler — it only copied
## files and shelled out to `odin build`. So it paid a full compiler rebuild
## to run subprocesses a shell runs natively. Then it was that shell script.

import std/[os, strutils]
import ../harness

const
  exampleDir = "examples"
  outDir = "tests/odin_out"
  rtDir = "compiler/tuckrt"

  # Examples whose emitted Odin must compile. Add one when it goes green so a
  # regression is a failure rather than a silent skip.
  odinCompile = """
01-data-flow 02-builder-mutation 03-functions-bake 04-sum-types-interface
05-actors-effects 06-transitions-example 07-comments 08-actors_isolated_state
09-decision-table 10-invariants 11-embedded-feature
12-transition-the-ctor-exception 13-arena-mem 15-type-attributes 17-input-merge
18-alias 19-event-registry 21-decision-bitmask 22-error-policy 23-units
24-stdlib 25-pools 26-actor-run 27-actor-select 31-fnsig-callback
32-duration-units
33-ffi-zlib 34-ffi-cstring 35-ffi-struct 36-ffi-enum-callback 37-ffi-handle
28-async-task 38-division 39-if-match-expr 40-saturating 41-tostr-concat
"""

  # Examples with a known exit code: these must RUN, not merely compile.
  #   26-actor-run     55  1+..+10 drained through the actor mailbox
  #   27-actor-select  55  same sum, but the handlers are `on select` arms —
  #                        which used to emit an actor with no mailbox and no
  #                        send procs, so the package did not compile
  #   31-fnsig-callback 42 40 + 2 through a baked callback slot
  #   33-ffi-zlib       0  real libz reached: compressBound(1000) == 1013
  #   34-ffi-cstring    0  libz's version via a real char*, compressBound right
  #   35-ffi-struct     0  C struct by value both ways, asserted in-program
  #   36-ffi-enum-callback 0  C enum with explicit values + a callback C invokes
  #   37-ffi-handle     0  opaque handle: C mallocs, derefs and frees it
  #   28-async-task    42  Odin coroutine runtime over minicoro really runs
  #   38-division       0  R1: /i truncates, /f does not — both backends agree
  #   39-if-match-expr  0  R2/R3: value-position if and match agree
  #   40-saturating     0  [saturating] must CLAMP (a miss returns 4464)
  #   41-tostr-concat   0  postfix application + unqualified call + concat
  #   24-stdlib         0  writeFile then readFile THROUGH THE OFFLOAD WORKER —
  #                        compile-only could not see that the round trip works
  odinRun = """26-actor-run:55 27-actor-select:55 31-fnsig-callback:42 33-ffi-zlib:0 34-ffi-cstring:0
35-ffi-struct:0 36-ffi-enum-callback:0 37-ffi-handle:0 28-async-task:42
38-division:0 39-if-match-expr:0 40-saturating:0 41-tostr-concat:0 24-stdlib:0"""

proc projFor(base: string): string = outDir / base.replace("-", "_")

proc stage(base: string) =
  ## Assemble a self-contained Odin package: the emitted main.odin, the Tuck
  ## runtime, any imported Tuck modules, and the C fixtures an FFI example
  ## binds against. The emitted `foreign import` path is relative to the
  ## package, so the objects must sit at the same relative spot inside the copy.
  let proj = projFor(base)
  removeDir(proj)
  createDir(proj / "tuckrt")
  if fileExists(exampleDir / base & ".odin"):
    copyFile(exampleDir / base & ".odin", proj / "main.odin")
  for f in walkFiles(rtDir / "*.odin"):
    copyFile(f, proj / "tuckrt" / f.lastPathPart)
  if fileExists(rtDir / "minicoro.a"):
    copyFile(rtDir / "minicoro.a", proj / "tuckrt" / "minicoro.a")
  if dirExists(exampleDir / "cffi"):
    createDir(proj / "cffi")
    for f in walkFiles(exampleDir / "cffi" / "*.c"):
      let o = proj / "cffi" / f.lastPathPart.changeFileExt("o")
      discard execShellCmd("cc -c -fPIC " & quoteShell(f) & " -o " &
                           quoteShell(o) & " 2>/dev/null")
  for modDir in walkDirs(exampleDir / "mod_*"):
    let d = proj / modDir.lastPathPart
    createDir(d)
    for f in walkFiles(modDir / "*.odin"):
      copyFile(f, d / f.lastPathPart)
  # Hand-written Odin packages named by `extern [impl: odin "./shim"]`. The
  # emitted import is relative to where the .odin sits, and this harness copies
  # it into an isolated package dir, so the package has to ride along too.
  if dirExists(exampleDir / "shim"):
    createDir(proj / "shim")
    for f in walkFiles(exampleDir / "shim" / "*.odin"):
      copyFile(f, proj / "shim" / f.lastPathPart)

proc run*(t: var T) =
  let odinExe = findOdin()
  if odinExe.len == 0:
    if t.phase != pReport: return
    if getEnv("TUCK_REQUIRE_ODIN") == "1":
      echo "FAIL: odin not found and TUCK_REQUIRE_ODIN=1"
      t.failed.inc
      return
    echo "SKIP Odin backend check: odin not found (set TUCK_REQUIRE_ODIN=1 to require it)."
    echo "odin_backend.sh: 0 passed, 0 failed"
    return

  if t.phase == pCollect:
    echo "Odin backend check with: " & odinExe
    createDir(outDir)

  var compileList: seq[string]
  for w in odinCompile.split({' ', '\n'}):
    if w.len > 0: compileList.add w

  # Each example builds into its OWN package dir and reads only shared inputs,
  # so the 35 `odin build` calls are independent — the runner's pool overlaps
  # them with everything else. Serial, this loop was 11.5s of the suite.
  #
  # The staging (copying runtime + fixtures into the package) has to happen
  # before each build, so it rides along as the prep hook rather than being
  # done up front — up front would serialize 35 directory trees before the
  # first compile started.
  var buildIdx: seq[tuple[base: string, idx: int]]
  for base in compileList:
    let proj = projFor(base)
    let b = base
    buildIdx.add (base, t.needCmdAfter(
      @[odinExe, "build", proj, "-o:none", "-out:" & proj / "prog"],
      -1,
      proc (dir: string) = stage(b),
      proj))

  # The run layer. Registered against the build it needs, so the pool sequences
  # them without this suite waiting on anything itself.
  var runIdx: seq[tuple[base: string, want: int, idx: int]]
  for entry in odinRun.split({' ', '\n'}):
    if entry.len == 0: continue
    let parts = entry.split(':')
    let base = parts[0]
    let want = parseInt(parts[1])
    var dep = -1
    for (b, i) in buildIdx:
      if b == base: dep = i
    let proj = projFor(base)
    runIdx.add (base, want, t.needCmdAfter(@[proj / "prog"], dep,
                                           proc (dir: string) = discard, proj))

  if t.phase != pReport: return

  for (base, i) in buildIdx:
    # Mode excluded the odin build; a `prog` left by an earlier full run must
    # not be read as this run's result.
    if t.skippedCmd(i): t.skip "compile " & base
    elif not fileExists(exampleDir / base & ".odin"):
      t.no "compile " & base,
        "missing emitted Odin (run `tuck c examples/" & base & ".tuck --odin` first)"
    elif fileExists(projFor(base) / "prog"):
      t.ok "compile " & base
    else:
      let (_, outp) = t.resultOf(i)
      var errs: seq[string]
      for l in outp.splitLines():
        if l.toLowerAscii.contains("error"): errs.add l
        if errs.len >= 3: break
      t.no "compile " & base, errs.join("\n")

  for (base, want, i) in runIdx:
    if t.skippedCmd(i): t.skip "run " & base; continue
    if not fileExists(projFor(base) / "prog"):
      t.no "run " & base, "no binary to run"
      continue
    let (rc, _) = t.resultOf(i)
    if rc == want: t.ok "run " & base & " -> " & $rc
    else: t.no "run " & base, "exited " & $rc & ", expected " & $want

  t.finish()
