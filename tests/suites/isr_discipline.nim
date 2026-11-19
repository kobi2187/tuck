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

  t.finish()
