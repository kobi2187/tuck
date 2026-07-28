# tests/odin_backend.nim
# End-to-end guard for the Odin backend: every gated example must compile
# with `odin build`, and the ones with a known answer must RUN and produce it.
#
# The run layer is the point. 26-actor-run compiled cleanly for a whole
# session while hanging forever at runtime (actors are daemons, so driving
# the scheduler for them never terminates) — a compile-only check called
# that a pass. Exit codes catch it.
#
# Skips with a notice when Odin is absent, unless TUCK_REQUIRE_ODIN=1, so
# CI can insist the check actually ran rather than silently vanishing.
import os, osproc, strutils

const
  exampleDir = "examples"
  outDir = "tests/odin_out"
  rtDir = "compiler/tuckrt"

# Examples whose emitted Odin must compile. Add one when it goes green so a
# regression is a failure rather than a silent skip.
const odinCheckExpected = [
  "01-data-flow", "02-builder-mutation", "03-functions-bake",
  "04-sum-types-interface", "05-actors-effects", "06-transitions-example",
  "07-comments", "08-actors_isolated_state", "09-decision-table",
  "10-invariants", "11-embedded-feature", "12-transition-the-ctor-exception",
  "13-arena-mem", "15-type-attributes", "17-input-merge", "18-alias",
  "19-event-registry", "21-decision-bitmask", "22-error-policy", "23-units",
  "24-stdlib", "25-pools", "26-actor-run", "31-fnsig-callback",
  "32-duration-units", "33-ffi-zlib", "34-ffi-cstring", "35-ffi-struct",
  "36-ffi-enum-callback", "37-ffi-handle",
]

# Examples with a known exit code: these must RUN, not merely compile.
const odinRunExpected = {
  "26-actor-run": 55,      # 1+..+10 drained through the actor mailbox
  "31-fnsig-callback": 42, # 40 + 2 through a baked callback slot
  # Direct C FFI: 0 only if the `foreign` binding really reached system libz
  # and compressBound(1000) returned 1013. A broken binding cannot fake it.
  "33-ffi-zlib": 0,
  # cstring across the FFI boundary: prints libz's version from a real char*
  # and still gets compressBound right.
  "34-ffi-cstring": 0,
  # C struct by value both directions: takesPoint(makesPoint(3,7)) == 307,
  # computed in C. Asserted in-program (an exit status is one byte).
  "35-ffi-struct": 0,
  # C enum with explicit values (a wrong one hits the C default: -999) and a
  # callback C invokes: applyOp(OP_MUL,6,7)==42 and callBack(:addTwo,40,2)==1042.
  "36-ffi-enum-callback": 0,
  # opaque handle: C mallocs, dereferences and frees it. 100 + 5 == 105.
  "37-ffi-handle": 0,
}

proc findOdin(): string =
  if findExe("odin") != "": return findExe("odin")
  for c in ["/home/kl/apps/Odin/odin", "/opt/odin/odin"]:
    if fileExists(c): return c
  ""

var failures = 0

proc buildOne(odinExe, baseName: string): tuple[ok: bool, output: string] =
  let projDir = outDir / baseName.replace("-", "_")
  removeDir(projDir)
  createDir(projDir)
  copyFile(exampleDir / (baseName & ".odin"), projDir / "main.odin")
  # the runtime and any imported Tuck modules ride along
  createDir(projDir / "tuckrt")
  for f in walkFiles(rtDir / "*.odin"):
    copyFile(f, projDir / "tuckrt" / extractFilename(f))
  if fileExists(rtDir / "minicoro.a"):
    copyFile(rtDir / "minicoro.a", projDir / "tuckrt" / "minicoro.a")
  # C fixtures an FFI example binds against (examples/cffi). The emitted
  # `foreign import` path is relative to the package, so the objects have to
  # sit at the same relative spot inside the copied project. Built on demand:
  # a .o is a build artifact, not something to commit.
  if dirExists(exampleDir / "cffi"):
    createDir(projDir / "cffi")
    for f in walkFiles(exampleDir / "cffi" / "*.c"):
      let obj = projDir / "cffi" / extractFilename(f).changeFileExt("o")
      discard execCmdEx("cc -c -fPIC " & quoteShell(f) & " -o " & quoteShell(obj))
  for modDir in walkDirs(exampleDir / "mod_*"):
    let dst = projDir / extractFilename(modDir)
    createDir(dst)
    for f in walkFiles(modDir / "*.odin"):
      copyFile(f, dst / extractFilename(f))
  let (output, rc) = execCmdEx(quoteShell(odinExe) & " build " &
                               quoteShell(projDir) & " -o:none -out:" &
                               quoteShell(projDir / "prog"))
  (rc == 0, output)

when isMainModule:
  let odinExe = findOdin()
  if odinExe == "":
    if getEnv("TUCK_REQUIRE_ODIN") == "1":
      echo "FAIL: odin not found and TUCK_REQUIRE_ODIN=1"
      quit(1)
    echo "SKIP Odin backend check: odin not found (set TUCK_REQUIRE_ODIN=1 to require it)."
    quit(0)

  createDir(outDir)
  echo "Odin backend check with: ", odinExe

  for baseName in odinCheckExpected:
    if not fileExists(exampleDir / (baseName & ".odin")):
      echo "  FAIL missing emitted Odin: ", baseName,
           " (run `tuck build examples/", baseName, ".tuck --odin` first)"
      failures.inc
      continue
    let (ok, output) = buildOne(odinExe, baseName)
    if not ok:
      echo "  FAIL compile: ", baseName
      for line in output.splitLines():
        if "Error" in line: echo "    ", line
      failures.inc
    else:
      echo "  PASS compile: ", baseName

  for (baseName, wantRc) in odinRunExpected:
    let prog = outDir / baseName.replace("-", "_") / "prog"
    if not fileExists(prog):
      echo "  FAIL no binary to run: ", baseName
      failures.inc
      continue
    let (_, rc) = execCmdEx(quoteShell(prog))
    if rc != wantRc:
      echo "  FAIL run: ", baseName, " exited ", rc, ", expected ", wantRc
      failures.inc
    else:
      echo "  PASS run: ", baseName, " -> ", rc

  if failures > 0:
    echo failures, " Odin backend check(s) failed"
    quit(1)
  echo "All Odin backend checks passed (", odinCheckExpected.len, " compile, ",
       odinRunExpected.len, " run)"
