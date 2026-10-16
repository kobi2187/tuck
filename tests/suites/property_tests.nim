## `tuck test --properties` (issue #68): property tests generated from the
## program. The effect-free fns that return a type with an `invariant:` are
## called with generated arguments (integers, bool, floats, str, enums,
## records, payload sums, `Seq` and `?` of those); the invariant is the
## property. Builds a harness per target, so this is a build-level suite.

import std/[os, strutils]
import ../harness

const Types = """
type Mode:
  | Fast
  | Slow

type Shape:
  | Dot
  | Disc({radius: f64})
  | Rect({w: int, h: int})

type Point:
  x: int
  y: int

type Chunk:
  index: int
  first: int
  last: int
  have: int
  invariant:
    first <= last
    have >= 0
    have <= (last - first) + 1
"""

proc run*(t: var T) =
  ## Registers the property-test assertions.
  t.src Types & """
fn spanOf({i: int, have: int}) -> Chunk:
  return {index: i, first: i, last: i + 5, have: have} Chunk

fn steady({a: int}) -> Chunk:
  return {index: 0, first: 0, last: 10, have: 3} Chunk

fn main() -> int:
  return 0
"""
  let out1 = t.curDir / "fails.txt"
  let run1 = t.needCmd(@["./tuck", "test", t.curDir / "t.tuck", "--properties",
                         "--cases:40", "--out:" & out1, "--root:" & t.root],
                       verb = vRun)
  if t.phase != pCollect:
    if t.skippedCmd(run1): t.skip "failures are counted and every failing call is written out"
    else:
      let (rc, outp) = t.resultOf(run1)
      let written = if fileExists(out1): readFile(out1) else: ""
      if rc == 0:
        t.no "failures are counted and every failing call is written out",
             "expected a failure, got: " & outp
      elif "spanOf: FAILED" notin outp or " of 40 cases" notin outp or
           "steady: 40 cases, Chunk invariant held" notin outp:
        t.no "failures are counted and every failing call is written out", outp
      elif "} spanOf    # Invariant violated on Chunk:" notin written or
           "steady" in written:
        t.no "failures are counted and every failing call is written out", written
      else:
        t.ok "failures are counted and every failing call is written out"

  t.src Types & """
fn rich({s: str, f: f64, m: Mode, items: Seq[int], note: int?, at: Point, sh: Shape}) -> Chunk:
  return {index: 0, first: 0, last: 0, have: at.x} Chunk

fn main() -> int:
  return 0
"""
  let out2 = t.curDir / "fails2.txt"
  let run2 = t.needCmd(@["./tuck", "test", t.curDir / "t.tuck", "--properties",
                         "--cases:30", "--out:" & out2, "--root:" & t.root],
                       verb = vRun)
  if t.phase != pCollect:
    if t.skippedCmd(run2): t.skip "str, float, enum, Seq, optional, record and payload-sum parameters are generated"
    else:
      let (_, outp) = t.resultOf(run2)
      let written = if fileExists(out2): readFile(out2) else: ""
      if "rich: FAILED" in outp and "Point" in written and "Shape." in written and
         "items: [" in written and "Mode." in written:
        t.ok "str, float, enum, Seq, optional, record and payload-sum parameters are generated"
      else:
        t.no "str, float, enum, Seq, optional, record and payload-sum parameters are generated",
             outp & "\n" & written

  t.src Types & """
fn spanOf({i: int, have: int}) -> Chunk:
  return {index: i, first: i, last: i + 5, have: have} Chunk

fn main() -> int:
  return 0
"""
  let run3 = t.needCmd(@["./tuck", "test", t.curDir / "t.tuck", "--properties",
                         "--cases:10", "--except:spanOf",
                         "--out:" & (t.curDir / "fails3.txt"), "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(run3)
    if rc == 0 and "no property targets" in outp:
      t.ok "--except leaves a function out"
    else:
      t.no "--except leaves a function out", outp

  t.src """
fn main() -> int:
  return 0
"""
  let none = t.needCmd(@["./tuck", "test", t.curDir / "t.tuck", "--properties",
                         "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(none)
    if rc == 0 and "no property targets" in outp:
      t.ok "a program with no target says so and succeeds"
    else:
      t.no "a program with no target says so and succeeds", outp

  t.src """
fn main() -> int:
  return 0
"""
  t.addFile "bad.tuck", """
type Pos:
  n: int
  invariant:
    n >= 0

fn make({n: int}) -> Pos:
  return {n: n} Pos
"""
  t.addFile "fine.tuck", """
type Pos:
  n: int
  invariant:
    n >= 0

fn make({n: u8}) -> Pos:
  return {n: n} Pos
"""
  let outDir = t.curDir / "dirfails.txt"
  let dirRun = t.needCmd(@["./tuck", "test", t.curDir, "--properties", "--cases:20",
                           "--out:" & outDir, "--root:" & t.root], verb = vRun)
  if t.phase != pCollect:
    if t.skippedCmd(dirRun): t.skip "a folder is scanned file by file into one report"
    else:
      let (rc, outp) = t.resultOf(dirRun)
      let written = if fileExists(outDir): readFile(outDir) else: ""
      if rc != 0 and "make: FAILED" in outp and "files scanned" in outp and
         "bad.tuck" in written and "fine.tuck" notin written:
        t.ok "a folder is scanned file by file into one report"
      else:
        t.no "a folder is scanned file by file into one report", outp & "\n" & written

  t.src Types & """
fn spanOf({i: int, have: int}) -> Chunk:
  return {index: i, first: i, last: i + 5, have: have} Chunk
"""
  let desc = t.needCmd(@["./tuck", "describe", t.curDir / "t.tuck", "--root:" & t.root],
                       verb = vCheck)
  if t.phase != pCollect:
    let (_, d) = t.resultOf(desc)
    if "[type Mode]\nkind = sum\nvariant = Fast" in d and
       "variant = Rect(w: int, h: int)" in d and "field = x: int" in d and
       "invariants = yes" in d and "[fn spanOf]\nreturns = Chunk\nparam = i: int" in d:
      t.ok "describe prints types and fns as INI text"
    else:
      t.no "describe prints types and fns as INI text", d

  t.finish()
