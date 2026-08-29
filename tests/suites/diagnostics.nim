## Every diagnostic code resolves, explains itself, and reaches the user.
##
## A code is a PROMISE: once published it names that diagnostic forever, so a
## user who searched for TK-TY05 last year must land on the same rule today.
## These tests hold the two halves of that promise — the code appears in the
## message the compiler prints, and `tuck explain` answers for it.

import std/[os, strutils, re, algorithm]
import ../harness

proc run*(t: var T) =
  # --- the code reaches the user -------------------------------------------

  t.src """
type A:
  x: int

type B:
  x: str

object C:
  + A
  + B

fn main() -> int:
  return 0
"""
  t.badCheck "a composed collision carries TK-TY05", "TK-TY05"

  t.src """
fn main() -> void:
  let x = 5.ms
  return
"""
  t.badCheck "an unresolvable name carries TK-TY03", "TK-TY03"

  # A parse rejection carries its code in the [stage code] tag rather than the
  # message body, so this asserts the tag the driver prints.
  t.src "ac:\n  t: int\n"
  let paIdx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])

  # A KEYWORD in a name-only position must name the collision. Found writing
  # stdlib types (FRICTIONS #5/#5c): "expected a field name" while pointing AT
  # one reads as a parser fault, not a naming one.
  t.src "type Q = {pending: str}\n"
  let rwPendingIdx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])
  t.src "type Z = {when: str}\n"
  let rwWhenIdx = t.needCmd(@["./tuck", "ch", t.curDir / "t.tuck"])

  # An ATTRIBUTE word is NOT a keyword: it is reserved only inside brackets, so
  # a name-only position takes it. `fn error(...)` is the log level's verb.
  # (FRICTIONS #5b — this used to be a parse error in a `pending:` block.)
  t.src """
pending:
  fn error({msg: str}) -> void
"""
  t.okCheck "an attribute word is a legal fn name in a pending block"

  # --- explain answers for every code --------------------------------------
  #
  # The registry is only useful if every code in it has an explanation. Walking
  # the enum by hand would go stale; this walks what the compiler actually
  # reports, so a code added without an explanation fails here.
  # Only DECLARED codes — `dcFoo = "TK-XX01"`. A bare TK-XX01 elsewhere in the
  # file is an illustration in a comment, not a registry entry, and matching
  # those reported two phantom codes the first time this ran.
  var codes: seq[string]
  for line in readFile("compiler/diagnostics.nim").splitLines():
    var m: array[1, string]
    if line.find(re"""= "(TK-[A-Z]{2}[0-9]{2})"""", m) >= 0:
      if m[0] notin codes: codes.add m[0]
  codes.sort()

  var explainIdx: seq[(string, int)]
  for c in codes:
    explainIdx.add (c, t.needCmd(@["./tuck", "explain", c]))

  # An unknown code must not be silently accepted.
  let unknownIdx = t.needCmd(@["./tuck", "explain", "TK-ZZ99"])
  # The short form is what a user actually types after reading an error.
  let shortIdx = t.needCmd(@["./tuck", "explain", "ty05"])

  if t.phase != pReport: return

  block:
    let (_, outp) = t.resultOf(paIdx)
    if outp.contains("TK-PA03"):
      t.ok "a misspelled top-level keyword carries TK-PA03"
    else:
      let ls = outp.splitLines()
      t.no "a misspelled top-level keyword carries TK-PA03",
           (if ls.len > 1: ls[1] else: outp)

  for (label, idx, word) in [("`pending`", rwPendingIdx, "pending"),
                             ("`when`", rwWhenIdx, "when")]:
    let name = "a reserved word as a field name names " & label & " (TK-PA08)"
    let (_, outp) = t.resultOf(idx)
    if outp.contains("TK-PA08") and outp.contains("`" & word & "` is a reserved word"):
      t.ok name
    else:
      let ls = outp.splitLines()
      t.no name, (if ls.len > 1: ls[1] else: outp)

  var missing = 0
  for (c, i) in explainIdx:
    let (_, outp) = t.resultOf(i)
    if outp.contains("no such diagnostic") or outp.contains("No code assigned"):
      echo "  no explanation: " & c
      missing.inc
  if missing == 0:
    t.ok "every code in the registry explains itself"
  else:
    t.no "every code in the registry explains itself", $missing & " without one"

  block:
    let (rc, _) = t.resultOf(unknownIdx)
    if rc == 0: t.no "an unknown code is rejected", "TK-ZZ99 was accepted"
    else: t.ok "an unknown code is rejected"

  block:
    let (_, outp) = t.resultOf(shortIdx)
    if outp.contains("set union"):
      t.ok "a code resolves without its TK- prefix, case-insensitively"
    else:
      let ls = outp.splitLines()
      t.no "a code resolves without its TK- prefix, case-insensitively",
           (if ls.len > 0: ls[0] else: "")

  t.finish()
