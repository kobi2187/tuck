## The resource registry's RUNTIME semantics — spec §7.4 — asserted against
## each of the three runtimes in its own language.
##
## Why not through a Tuck program, like every other suite: there is no
## Tuck-level acquire surface yet (docs/resources.md §2 says why, and why
## inventing one ahead of the spec would be the wrong move). These rules are
## what §7.4 is actually made of — strict/lazy/exit, the inline watermark,
## LIFO close-all, the generation bump that kills a handle at its mark — so
## leaving them unpinned until that surface exists would mean shipping the
## whole registry unverified.
##
## The three programs assert the IDENTICAL list. That is the point: three
## runtimes, one behaviour. A change that drifts one of them fails here
## naming which.
##
## Registered as a non-quick suite: each arm compiles and runs a real program.

import std/[os, strutils, osproc]
import ../harness

const NimCheck = "tests/rt_resources/nim_check.nim"
const OdinDir  = "tests/rt_resources/odin"
const DCheck   = "tests/rt_resources/d_check.d"

proc reportArm(t: var T, backend: string, idx: int) =
  ## One runtime's verdict. The program prints its own PASS/FAIL lines and
  ## exits non-zero if any failed, so this reports the WHOLE arm — and on a
  ## failure passes the program's output through, since that output names the
  ## rule that broke.
  if t.phase == pCollect: return
  if t.wasSkipped(idx):
    t.skip backend & ": the registry behaves as §7.4 specifies"
    return
  let (rc, outp) = t.resultOf(idx)
  if rc == 0:
    t.ok backend & ": the registry behaves as §7.4 specifies (" &
        $outp.count("PASS") & " rules)"
  else:
    t.no backend & ": the registry behaves as §7.4 specifies", outp.strip()

proc run*(t: var T) =
  # --- Nim -----------------------------------------------------------------
  # Always available: it is what builds the compiler.
  let nimIdx = t.needCmd(@["nim", "c", "--hints:off", "-r",
                           "-o:" & (t.dir / "nim_rt_check"),
                           t.root / NimCheck], verb = vBuild)
  t.reportArm("Nim", nimIdx)

  # --- Odin ----------------------------------------------------------------
  # `odin run` takes a DIRECTORY and needs the runtime package beside the
  # program, so the tuckrt copy is staged between the two — which is exactly
  # the shape needCmdAfter exists for.
  let odinExe = findOdin()
  if odinExe.len > 0:
    let odinOut = t.dir / "odin_rt"
    let src = t.root / OdinDir
    let rtSrc = t.root / "compiler" / "tuckrt"
    let stage = proc (dir: string) =
      createDir(odinOut)
      copyFile(src / "main.odin", odinOut / "main.odin")
      copyDir(rtSrc, odinOut / "tuckrt")
    # No dependency to wait on — stage immediately and run. needCmd plus a
    # prep step is needCmdAfter's shape, so it rides the Nim arm as the dep:
    # if Nim's own check cannot even build, the Odin one tells us nothing new.
    let odinIdx = t.needCmdAfter(@[odinExe, "run", odinOut,
                                   "-out:" & (t.dir / "odin_rt_check")],
                                 nimIdx, stage, odinOut, verb = vBuild)
    t.reportArm("Odin", odinIdx)
  elif t.phase == pReport:
    if getEnv("TUCK_REQUIRE_ODIN") == "1":
      t.no "Odin: the registry behaves as §7.4 specifies",
           "odin not found and TUCK_REQUIRE_ODIN=1"
    else:
      t.skip "Odin: the registry behaves as §7.4 specifies"

  # --- D -------------------------------------------------------------------
  let dmdExe = findDmd()
  if dmdExe.len > 0:
    # `-i` and the runtime's own directory on the include path; `-run` must
    # come last, with the source right after it.
    #
    # minicoro.a rides along for the same reason harness.hostBuilds passes it:
    # tuck_rt.d re-exports tuck_coro.d, so ANY program touching the D runtime
    # pulls in the coroutine engine and needs the C object to link against.
    # Without it the check died in the LINKER — "undefined reference to
    # mco_create" — which reads like a resources defect and is not one.
    let dOut = t.dir / "d_rt_check"
    let dIdx = t.needCmd(@[dmdExe, "-i",
                           "-I" & (t.root / "compiler" / "tuckrt_d"),
                           t.root / "compiler" / "tuckrt" / "minicoro.a",
                           "-of=" & dOut, "-run", t.root / DCheck],
                         verb = vBuild)
    t.reportArm("D", dIdx)
  elif t.phase == pReport:
    if getEnv("TUCK_REQUIRE_D") == "1":
      t.no "D: the registry behaves as §7.4 specifies",
           "dmd not found and TUCK_REQUIRE_D=1"
    else:
      t.skip "D: the registry behaves as §7.4 specifies"
