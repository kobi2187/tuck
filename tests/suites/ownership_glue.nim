## Rule G. Native/generated runtime tests keep failures independent of
## compiler lowering; end-to-end tests gate each later integration step.
import std/os
import ../harness

proc run*(t: var T) =
  t.src """
import seq

fn first({xs: Seq[Seq[int]]}) -> Seq[int]:
  var copied = xs
  return copied[0]

fn main() -> int:
  let xs: Seq[Seq[int]] = [[1, 2], [3]]
  let row = {xs: xs} first
  return row[0] + xs[1][0]
"""
  t.emitsD "G: D copy nodes invoke recursive glue", "rt.tuckCopyG\\("
  t.hostRuns "G: nested copies preserve results across backends", 4
  t.src """
fn identity({xs: Seq[Seq[int]]}) -> Seq[Seq[int]]:
  return xs

fn main() -> int:
  let xs: Seq[Seq[int]] = [[1, 2]]
  let ys = {xs: xs} identity
  return xs[0][0] + ys[0][1]
"""
  t.emitsD "G: D borrowing twin wrappers invoke recursive glue", "rt.tuckCopyG\\("
  t.src """
actor Inbox [queue: 8]:
  on receive({xs: Seq[Seq[int]]}):
    let n = xs.len

fn main() -> int:
  Inbox send receive {xs: [[1, 2]]}
  return 0
"""
  t.emitsD "G: D mailbox payload copies invoke recursive glue", "rt.tuckCopyG\\("
  let shape = t.needCmd(@["nim", "c", "--hints:off", "--warnings:off",
                          "-r", "-o:" & (t.dir / "glue_shapes"),
                          t.root / "tests" / "ownership_glue" / "shapes.nim"],
                        verb = vBuild)
  if t.phase == pReport:
    if t.skippedCmd(shape):
      t.skip "G: shared type graph covers nested and recursive owning types"
    else:
      let (rc, output) = t.resultOf(shape)
      if rc == 0: t.ok "G: shared type graph covers nested and recursive owning types"
      else: t.no "G: shared type graph covers nested and recursive owning types", output
  let dmd = findDmd()
  if dmd.len > 0:
    let dExe = t.dir / "glue_d"
    let dBuild = t.needCmd(@[dmd, "-i",
      "-I" & (t.root / "compiler" / "tuckrt_d"),
      t.root / "compiler" / "tuckrt" / "minicoro.a",
      "-of=" & dExe, t.root / "tests" / "ownership_glue" / "copy.d"], verb = vBuild)
    let dRun = t.needCmdAfter(@["timeout", "10", dExe], dBuild,
                             proc (dir: string) = discard, t.dir, verb = vRun)
    if t.phase == pReport:
      if t.skippedCmd(dRun):
        t.skip "G: D deep copies preserve nested value semantics with native GC"
      else:
        let (rc, output) = t.resultOf(dRun)
        if rc == 0: t.ok "G: D deep copies preserve nested value semantics with native GC"
        else:
          let (buildRc, buildOutput) = t.resultOf(dBuild)
          t.no "G: D deep copies preserve nested value semantics with native GC",
               if buildRc != 0: buildOutput else: output
  let odin = findOdin()
  if odin.len == 0:
    if t.phase == pReport:
      t.no "G: recursive sequence copy/drop requires Odin", "odin not installed"
    return
  let generated = t.dir / "generated"
  let gen = t.needCmd(@["nim", "c", "--hints:off", "--warnings:off", "-r",
    "-o:" & (t.dir / "glue_generator"),
    t.root / "tests" / "ownership_glue" / "generate.nim", generated], verb = vBuild)
  let genBuild = t.needCmdAfter(@[odin, "build", generated, OdinThreads,
    "-define:TUCK_TRACK=true", "-out:" & (generated / "prog")],
    gen, proc (dir: string) = discard, t.dir, verb = vBuild)
  let genRun = t.needCmdAfter(@["timeout", "10", generated / "prog"],
    genBuild, proc (dir: string) = discard, t.dir, verb = vRun)
  if t.phase == pReport:
    if t.skippedCmd(genRun):
      t.skip "G: generated Odin record/sum/array/result glue is leak-free"
    else:
      let (rc, output) = t.resultOf(genRun)
      if rc == 0:
        t.ok "G: generated Odin record/sum/array/result glue is leak-free"
      else:
        let (buildRc, buildOutput) = t.resultOf(genBuild)
        t.no "G: generated Odin record/sum/array/result glue is leak-free",
             if buildRc != 0: buildOutput else: output
