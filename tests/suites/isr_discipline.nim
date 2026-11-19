## The ISR shared-state inventory (`tuck audit --isr`).
##
## The report is the shared-data table embedded teams keep on paper, generated
## from the checked program. This suite pins that the developer sees BOTH sides
## of a shared access — the ISR and the normal code — with source locations.

import std/[os, strutils, sequtils]
import ../harness

proc auditSays(t: var T, name: string, wanted: seq[string]) =
  let idx = t.needCmd(@["./tuck", "audit", t.curDir / "t.tuck", "--isr"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc != 0:
    t.no name, "audit failed: " & text
  elif wanted.allIt(strutils.contains(text, it)):
    t.ok name
  else:
    t.no name, "audit did not name every site. Got: " & text

proc gateSays(t: var T, name, pattern: string) =
  ## The gate must reject with a clean TK-EF10 that names BOTH contexts.
  let idx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--isr-check:error"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc == 0:
    t.no name, "gate accepted shared ISR state"
  elif strutils.contains(text, pattern) and strutils.contains(text, "TK-EF10"):
    t.ok name
  else:
    t.no name, "wrong gate diagnostic: " & text

proc formatSays(t: var T, name, flag, pattern: string) =
  let idx = t.needCmd(@["./tuck", "audit", t.curDir / "t.tuck", "--isr", flag])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc == 0 and strutils.contains(text, pattern): t.ok name
  else: t.no name, "wrong " & flag & " report: " & text

proc gateSays11(t: var T, name, pattern: string) =
  let idx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc == 0:
    t.no name, "critical: with I/O was accepted"
  elif strutils.contains(text, pattern) and strutils.contains(text, "TK-EF11"):
    t.ok name
  else:
    t.no name, "wrong TK-EF11 diagnostic: " & text

proc gateAllows(t: var T, name: string) =
  let idx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck", "--isr-check:error"])
  if t.phase == pCollect: return
  let (rc, text) = resultOf(t, idx)
  if rc == 0: t.ok name
  else: t.no name, "gate rejected a fully protected program: " & text

proc run*(t: var T) =
  t.src """
register FLAG at 0x40000000:
  VALUE: bits 0..7 [read, write]

fn isr() [irq, irq_safe, no_alloc]:
  FLAG.VALUE = 1
  return

fn main() -> int:
  FLAG.VALUE = 2
  return 0
"""
  t.auditSays "ISR audit names both writers by signature and the shared register", @[
    "ISR", "isr() [irq, irq_safe, no_alloc] writes",
    "main() -> int writes", "FLAG"]
  t.gateSays "TK-EF10 gate names both contexts", "normal code main() -> int"

  t.formatSays "audit --format:json emits a finding",
               "--format:json", "\"code\": \"TK-EF10\""
  t.formatSays "audit --format:sarif emits a SARIF 2.1.0 run",
               "--format:sarif", "\"version\": \"2.1.0\""


  # A `critical:` block around BOTH accesses makes the same program safe.
  t.src """
register FLAG at 0x40000000:
  VALUE: bits 0..7 [read, write]

fn isr() [irq, irq_safe, no_alloc]:
  critical:
    FLAG.VALUE = 1
  return

fn main() -> int:
  critical:
    FLAG.VALUE = 2
  return 0
"""
  t.gateAllows "critical: protects shared ISR state"
  t.auditSays "audit marks critical: accesses as protected", @[
    "[protected: critical:]", "All shared accesses are inside critical"]

  # A critical: block may not hold a capability effect: interrupts stay off.
  t.src """
extern [impl: nim "./host_sim/hal_shim", odin "./host_sim", d "./host_sim/hal_shim"]:
  fn say({text: str}) -> void [io]

fn main() -> int [io]:
  critical:
    {text: "hi\n"} say
  return 0
"""
  t.gateSays11 "TK-EF11 refuses I/O inside critical:", "would stay disabled"

  # Machine-readable findings: jq-friendly JSON and standard SARIF 2.1.0.
  t.finish()
