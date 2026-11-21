## `tuck timing` — the static timing report.
##
## Pins three things a developer depends on:
##   - critical-section nesting is counted, and nesting > 1 is called out;
##   - the worst-case stack SUMS the call path (it is not the largest frame);
##   - JSON and SARIF are parseable, and only a real issue (nesting > 1) is a
##     SARIF result — a flat inventory stays text/JSON.

import std/[json, os, strutils, sequtils]
import ../harness

proc hasNote(notes: JsonNode, part: string): bool =
  ## A note may sit among several; look for the fragment the assertion needs.
  for note in notes:
    if note.getStr.contains(part): return true
  false

proc timingSays(t: var T, name: string, wanted: seq[string]) =
  let idx = t.needCmd(@["./tuck", "timing", t.curDir / "t.tuck"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0:
    t.no name, "timing failed: " & text
  elif wanted.allIt(strutils.contains(text, it)):
    t.ok name
  else:
    t.no name, "timing did not say every part. Got: " & text

proc timingJson(t: var T, name: string, check: proc (n: JsonNode): bool) =
  let idx = t.needCmd(@["./tuck", "timing", t.curDir / "t.tuck", "--format:json"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0:
    t.no name, "timing --format:json failed: " & text
    return
  try:
    if check(parseJson(text)): t.ok name
    else: t.no name, "JSON did not carry the expected shape: " & text
  except JsonParsingError as e:
    t.no name, "JSON did not parse: " & e.msg

proc timingSarif(t: var T, name: string, wanted: seq[string],
                 forbidden: seq[string] = @[]) =
  let idx = t.needCmd(@["./tuck", "timing", t.curDir / "t.tuck", "--format:sarif"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0:
    t.no name, "timing --format:sarif failed: " & text
    return
  try:
    let doc = parseJson(text)
    let ids = doc["runs"][0]["results"].getElems.mapIt(it["ruleId"].getStr)
    if wanted.allIt(it in ids) and not forbidden.anyIt(it in ids):
      t.ok name
    else:
      t.no name, "SARIF rule ids were " & $ids
  except JsonParsingError as e:
    t.no name, "SARIF did not parse: " & e.msg

proc run*(t: var T) =
  # A nested critical: is counted at depth 2, and the text says so.
  t.src """
extern [impl: nim "./host_sim/print_shim", odin "./host_sim", d "./host_sim/print_shim"]:
  fn say({text: str}) -> void

register FLAG at 0x40000000:
  VALUE: bits 0..7 [read, write]

fn top({}) -> int:
  critical:
    critical:
      FLAG.VALUE = 3
  return 0

fn main() -> int:
  let r = {} top
  return r
"""
  t.timingSays "nested critical: is reported at depth 2", @[
    "2x", "top()", "nested"]

  t.timingJson "JSON carries critical depth and a fnId", proc (n: JsonNode): bool =
    n["critical"].len == 1 and
      n["critical"][0]["depth"].getInt == 2 and
      n["critical"][0]["fn"].getStr == "top()" and
      n["critical"][0]["fnId"].getStr.len > 0

  # The stack report SUMS the call path: leaf < middle < top < main.
  t.src """
extern [impl: nim "./host_sim/print_shim", odin "./host_sim", d "./host_sim/print_shim"]:
  fn say({text: str}) -> void

fn leaf({x: int}) -> int:
  return x + 1

fn middle({x: int}) -> int:
  let y = {x: x} leaf
  return y + 1

fn top({}) -> int:
  return {x: 1} middle

fn main() -> int:
  let r = {} top
  return r
"""
  t.timingSays "stack report names the deepest path first", @[
    "main()", "top()", "middle({x: int})", "leaf({x: int})",
    "via top() -> middle({x: int}) -> leaf({x: int})"]

  t.timingJson "stack bytes accumulate along the call path", proc (n: JsonNode): bool =
    var byName: seq[(string, int)]
    for e in n["stack"].getElems:
      byName.add (e["fn"].getStr, e["bytesApprox"].getInt)
    proc bytesOf(name: string): int =
      for (fn, b) in byName:
        if fn == name: return b
      -1
    bytesOf("main()") > bytesOf("top()") and
      bytesOf("top()") > bytesOf("middle({x: int})") and
      bytesOf("middle({x: int})") > bytesOf("leaf({x: int})")

  t.timingJson "JSON names the call path, not just the total", proc (n: JsonNode): bool =
    let p = n["stack"][0]["callPath"]
    p.len == 4 and p[0].getStr == "main()" and p[3].getStr == "leaf({x: int})"

  # SARIF: nesting > 1 is a result; the stack notes are results too.
  t.src """
extern [impl: nim "./host_sim/print_shim", odin "./host_sim", d "./host_sim/print_shim"]:
  fn say({text: str}) -> void

register FLAG at 0x40000000:
  VALUE: bits 0..7 [read, write]

fn top({}) -> int:
  critical:
    critical:
      FLAG.VALUE = 3
  return 0

fn main() -> int:
  let r = {} top
  return r
"""
  t.timingSarif "SARIF flags nested critical: with TK-TM01", @["TK-TM01"]
  t.timingSarif "SARIF carries stack notes as TK-TM02", @["TK-TM02"]

  # A single critical: block is inventory, not a finding.
  t.src """
extern [impl: nim "./host_sim/print_shim", odin "./host_sim", d "./host_sim/print_shim"]:
  fn say({text: str}) -> void

register FLAG at 0x40000000:
  VALUE: bits 0..7 [read, write]

fn main() -> int:
  critical:
    FLAG.VALUE = 2
  return 0
"""
  t.timingSays "a single critical: block is still reported in text", @["1x", "main()"]
  t.timingSarif "a single critical: block is not a SARIF finding", @[],
                @["TK-TM01"]

  # A task body owns its own stack, and a critical: inside it must be seen.
  t.src """
extern [impl: nim "./host_sim/print_shim", odin "./host_sim", d "./host_sim/print_shim"]:
  fn say({text: str}) -> void

register FLAG at 0x40000000:
  VALUE: bits 0..7 [read, write]

task worker() -> int:
  critical:
    FLAG.VALUE = 1
  return 0

fn main() -> int:
  let h = {} worker
  return 0
"""
  t.timingSays "a task's critical: block is reported, not missed", @[
    "1x", "worker()"]
  t.timingJson "a task appears in the stack report as its own root", proc (n: JsonNode): bool =
    n["stack"].getElems.anyIt(it["fn"].getStr == "worker()")

  # The codes are registered and explainable, as warnings.
  let e1 = t.needCmd(@["./tuck", "explain", "TK-TM01"])
  if t.phase != pCollect:
    let (rc, text) = resultOf(t, e1)
    if rc == 0 and strutils.contains(text, "Timing Warning"):
      t.ok "TK-TM01 explains as a Timing Warning"
    else:
      t.no "TK-TM01 explains as a Timing Warning", text
  let e2 = t.needCmd(@["./tuck", "explain", "TK-TM02"])
  if t.phase != pCollect:
    let (rc, text) = resultOf(t, e2)
    if rc == 0 and strutils.contains(text, "Timing Warning"):
      t.ok "TK-TM02 explains as a Timing Warning"
    else:
      t.no "TK-TM02 explains as a Timing Warning", text

  # --- coarse cycle score (the scoring function, report-only) -------------
  # A caller's score includes its callees' scores; names are display only,
  # identity is fnId. Nothing here is measured or enforced.
  t.src """
fn leaf({x: int}) -> int:
  return x + 1

fn top({}) -> int:
  let y = {x: 1} leaf
  return y + 1

fn main() -> int:
  let r = {} top
  return r
"""
  t.timingSays "the report prints a coarse cycle score per fn", @[
    "Worst-case cycles", "cyc", "main()", "top()", "leaf({x: int})"]
  t.timingJson "cycle scores accumulate along the call graph", proc (n: JsonNode): bool =
    var byName: seq[(string, int)]
    for e in n["cost"].getElems:
      byName.add (e["fn"].getStr, e["cyclesApprox"].getInt)
    proc cyclesOf(name: string): int =
      for (fn, c) in byName:
        if fn == name: return c
      -1
    cyclesOf("main()") > cyclesOf("top()") and
      cyclesOf("top()") > cyclesOf("leaf({x: int})") and
      n["cost"].getElems.allIt(it["exact"].getBool)

  # A constant range is a provable trip count: ten iterations must cost more
  # than two, and both stay an exact (bounded) estimate.
  t.src """
fn small({}) -> int:
  var s = 0
  for i in 1 .. 2:
    s = s + 1
  return s

fn big({}) -> int:
  var s = 0
  for i in 1 .. 10:
    s = s + 1
  return s

fn main() -> int:
  return 0
"""
  t.timingJson "a constant loop bound is multiplied into the body", proc (n: JsonNode): bool =
    var small = -1
    var big = -1
    for e in n["cost"].getElems:
      if e["fn"].getStr == "small()": small = e["cyclesApprox"].getInt
      if e["fn"].getStr == "big()": big = e["cyclesApprox"].getInt
    big > small * 2

  # A parameter bound is NOT guessed: the body is counted once, the score is
  # marked inexact, and the text refuses to call it a hard bound.
  t.src """
fn dyn({n: int}) -> int:
  var s = 0
  for i in 0 .. n - 1:
    s = s + 1
  return s

fn main() -> int:
  return 0
"""
  t.timingSays "an unprovable loop is flagged, not silently bounded", @[
    "[not a hard bound]", "loop bound not provable; body counted once"]
  t.timingJson "an inexact score carries its reason", proc (n: JsonNode): bool =
    n["cost"].getElems.anyIt(it["fn"].getStr == "dyn({n: int})" and
      not it["exact"].getBool and
      hasNote(it["notes"], "not provable"))

  # IO has no static cost model. It must be listed as a note, never a number
  # that looks authoritative.
  t.src """
extern [impl: nim "./host_sim/print_shim", odin "./host_sim", d "./host_sim/print_shim"]:
  fn say({text: str}) -> void

fn main() -> int:
  {text: "hi\n"} say
  return 0
"""
  t.timingJson "an IO call is reported as unmodelled", proc (n: JsonNode): bool =
    n["cost"].getElems.anyIt(hasNote(it["notes"], "not modelled"))

  t.finish()
