## SVD imports: a register declared in a module, used from its importer.
##
## The parser never treated `register` as an importable declaration, so even
## after the checker copied one in the backends emitted a bare accessor name
## that lived in the defining module's output. Nim's import merges names and
## hid the defect; Odin and D both rejected it. This suite pins the qualified
## accessor on all three.
##
## The second half is T8's zero-register-diff claim. `bare_metal_led.tuck`
## declares five registers by hand; `stm32f103_bluepill.tuck` is generated from
## the Apache-2.0 STM32F103 SVD. Their addresses and fields must agree exactly
## or the generated module is not a drop-in replacement.

import std/[os, strutils, tables, algorithm]
import ../harness

proc registerAddress(path, name: string): string =
  ## The `0x...` operand of `register NAME at 0x...:` in `path`, or "".
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if not line.startsWith("register "): continue
    let words = line.splitWhitespace()
    if words.len >= 4 and words[1] == name: return words[3].strip(chars = {':'})
  ""

proc registerFields(path, name: string): seq[string] =
  ## The field lines of one register, whitespace-normalised. Generated output
  ## pads the names into columns; the hand-written fixture does not.
  var inside = false
  for raw in readFile(path).splitLines():
    let line = raw.strip()
    if line.startsWith("register "):
      inside = line.splitWhitespace()[1] == name
      continue
    if not inside: continue
    if line == "": inside = false
    elif ':' in line: result.add line.splitWhitespace().join(" ")
  result.sort()

proc run*(t: var T) =
  # --- imported register accessors and full-width fields ------------------
  t.src """
import regs

register DATA at 0x40000004:
  DATA: bits 0..31 [read, write]

fn main() -> int:
  CTRL.EN = true
  DATA.DATA = 7
  if CTRL.EN:
    return 0
  return 1
"""
  t.addFile "regs.tuck", """register CTRL at 0x40000000:
  EN: bit 0 [read, write]
"""
  t.okCheck "a register crosses the module boundary"
  t.emitsOdin "Odin qualifies an imported register's setter with its module",
              r"tuckˑmodˑregs\.tuckˑregisterˑCTRL_EN_set"
  t.emitsD "D qualifies an imported register's setter with its module",
           r"tuckˑmodˑregs\.tuckˑregisterˑCTRL_EN_set"
  t.emits "a 32-bit field's Nim mask shifts a full word right",
          r"0xFFFFFFFF'u32 shr \(32 - tuckˑregisterˑDATA_DATA_WIDTH\)"
  t.emitsOdin "...and so does Odin's",
              r"u32\(0xffffffff\) >> u32\(32 - tuckˑregisterˑDATA_DATA_WIDTH\)"
  t.emitsD "...and so does D's",
           r"0xffffffffu >> \(32 - tuckˑregisterˑDATA_DATA_WIDTH\)"
  # No host RUN: a register is a raw pointer to real MMIO. Build acceptance on
  # all three backends is what this defect can break.
  t.hostBuilds "the imported read/write program builds on every backend"

  # --- zero register diff against the hand-written board fixture ----------
  let hand = t.root / "testing_experiment" / "bare_metal_led.tuck"
  let genDir = t.root / "testing_experiment" / "tools" / "svd2tuck" /
               "generated"
  let gen = genDir / "stm32f103_bluepill.tuck"
  let check = t.needCmd(@[t.root / "tuck", "ch", gen, "--root:" & t.root])
  if t.phase == pReport:
    if t.skippedCmd(check): t.skip "the generated module checks cleanly"
    else:
      let (rc, output) = t.resultOf(check)
      if rc == 0: t.ok "the generated module checks cleanly"
      else: t.no "the generated module checks cleanly", output.splitLines()[^1]

  if t.phase == pReport:
    for (name, address) in [
        ("RCC_APB2ENR", "0x40021018"),
        ("GPIOC_CRH", "0x40011004"),
        ("GPIOC_ODR", "0x4001100C")]:
      let want = registerFields(hand, name)
      let got = registerFields(gen, name)
      if want.len == 0:
        t.no name & ": the hand-written fixture still declares it", "no fields found"
      elif registerAddress(hand, name) != address:
        t.no name & ": the hand-written address changed",
              registerAddress(hand, name)
      elif registerAddress(gen, name) != address:
        t.no name & ": the generated address changed",
              registerAddress(gen, name)
      else:
        # The SVD describes the whole peripheral; the fixture only uses five
        # of its fields. Every field the fixture declares must appear in the
        # generated register with the same bit range and access, verbatim.
        var missing: seq[string]
        for w in want:
          if w notin got: missing.add w
        if missing.len > 0:
          t.no name & ": the generated register lost or changed a used field",
                $missing & "\ngenerated: " & $got
        else:
          t.ok name & ": generated address and used fields match the fixture"

  t.finish()
