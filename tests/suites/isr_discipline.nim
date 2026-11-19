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

  t.finish()
