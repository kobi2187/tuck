## Optional optimization passes (compiler/optimize.nim).
##
## An optimization makes a different KIND of claim from the rest of the
## compiler: not "this program means X" but "this program still means X,
## written faster". So these are EQUIVALENCE tests first and shape tests
## second — every case that asserts the emitted code changed also asserts the
## program still produces the same answer, because a pass that silently
## changes behaviour is a miscompile, and a shape test alone would not catch
## one.
##
## Two properties matter most and are checked here before anything else:
##
##   1. OFF BY DEFAULT IS INERT. Without `-O`, the emitted code must be
##      byte-identical to a build of a compiler that never had this file.
##      That is what lets a pass be landed, measured, and deleted on its own.
##   2. ON PRESERVES MEANING. Same source, same exit code, with and without.

import std/[os, strutils]
import ../harness

# The canonical builder from spec §2.3 / examples/02-builder-mutation: a
# mutator that ignores its receiver and returns a fresh value. `..withDefaults`
# lowers to `cfg = withDefaults(cfg)` — a record in, a record out — and the
# pass rewrites it to the construction itself, deleting the call.
const wholeValueSrc = """
type Cfg:
  port: int
  timeout: int

fn withDefaults({self: Cfg}) -> Cfg:
  return {port: 80, timeout: 30} Cfg

fn main() -> int:
  var cfg = {port: 0, timeout: 0} Cfg
  cfg ..withDefaults ..port {60}
  return cfg.port + cfg.timeout
"""

# The other builder shape: copy the receiver into a temp, mutate the temp,
# return it. Lowers to three copies of the record (in, out, back); the pass
# splices the temp's own field-sets into the caller's chain instead.
const tempAndMutateSrc = """
type Cfg:
  port: int
  timeout: int

fn withDefaults({self: Cfg}) -> Cfg:
  var s = self
  s ..timeout {30}
  return s

fn main() -> int:
  var cfg = {port: 1, timeout: 0} Cfg
  cfg ..withDefaults
  return cfg.port + cfg.timeout
"""

proc emittedWith(t: var T, tag: string, flags: seq[string]): string =
  ## Emit the current snippet with extra CLI flags, returning the Nim source.
  let outDir = t.curDir / ("emit_" & tag)
  var argv = @["./tuck", "c", t.curDir / "t.tuck", "-o:" & outDir,
               "--root:" & t.root]
  for f in flags: argv.add f
  let i = t.needCmd(argv)
  if t.phase == pCollect: return ""
  let (rc, outp) = t.resultOf(i)
  if rc != 0: return "EMIT FAILED: " & outp
  let p = outDir / "t.nim"
  if fileExists(p): readFile(p) else: ""

proc run*(t: var T) =
  # --- 1. ON by default, and -O:none is the escape hatch -------------------
  #
  # Passes run unless told otherwise (2026-08-14). `-O:none` must still turn
  # them all off: when emitted code looks wrong, "does -O:none change the
  # answer" is the first question, and it needs to be askable without
  # rebuilding the compiler.

  t.src wholeValueSrc
  let plainOff = t.emittedWith("off", @["-O:none"])
  let plainOn = t.emittedWith("on", @[])
  if t.phase != pCollect:
    if plainOff.startsWith("EMIT FAILED") or plainOn.startsWith("EMIT FAILED"):
      t.no "a pass changes the emitted code when asked for", plainOff & plainOn
    elif plainOff == plainOn:
      t.no "a pass changes the emitted code when asked for",
           "-O:none emitted the same text as the default"
    else:
      t.ok "a pass changes the emitted code when asked for"

    # -O:none is genuinely inert: the call survives untouched.
    if "tuck_withDefaults(" in plainOff:
      t.ok "-O:none leaves the mutator call unchanged"
    else:
      t.no "-O:none leaves the mutator call unchanged",
           "the call is gone even with -O:none: " & plainOff

  # --- 2. the whole-value builder loses its call ---------------------------

  if t.phase != pCollect:
    if "tuck_withDefaults(" notin plainOn and "tuck_Cfg(port: 80" in plainOn:
      t.ok "a receiver-independent builder is replaced by its own value"
    else:
      t.no "a receiver-independent builder is replaced by its own value",
           "expected the construction inline, got: " & plainOn

  # ...and still computes the same answer: port 60 (set after the builder)
  # + timeout 30 = 90. Kept well under 127: a Nim-built binary in this
  # environment reports any exit code >= 127 as 127, which is why every gate
  # in this suite picks a small number.
  t.runs "the whole-value rewrite preserves the result (off)", 90

  # --- 3. the temp-and-mutate builder loses its copies ---------------------

  t.src tempAndMutateSrc
  let tmOff = t.emittedWith("off", @["-O:none"])
  let tmOn = t.emittedWith("on", @[])
  if t.phase != pCollect:
    if "tuck_withDefaults(" in tmOff and "tuck_withDefaults(" notin tmOn and
       "cfg.timeout = 30" in tmOn:
      t.ok "a temp-and-mutate builder is spliced into the caller's chain"
    else:
      t.no "a temp-and-mutate builder is spliced into the caller's chain",
           "off=[" & tmOff.strip() & "] on=[" & tmOn.strip() & "]"

  t.runs "the splice rewrite preserves the result (off)", 31

  # --- 4. what the pass must REFUSE ---------------------------------------
  #
  # A builder whose body reads its own receiver is a real call: rewriting it
  # would need to know whether an earlier step already wrote the field being
  # read, which is exactly the dataflow this pass exists to avoid. It must be
  # left alone rather than approximated.

  t.src """
type Cfg:
  port: int
  timeout: int

fn bump({self: Cfg}) -> Cfg:
  var s = self
  s ..port {self.port}
  return s

fn main() -> int:
  var cfg = {port: 7, timeout: 0} Cfg
  cfg ..bump
  return cfg.port
"""
  let refuseOn = t.emittedWith("on", @["-O:chain-inplace"])
  if t.phase != pCollect:
    if "tuck_bump(" in refuseOn:
      t.ok "a builder that reads its receiver is left alone"
    else:
      t.no "a builder that reads its receiver is left alone",
           "the call was rewritten anyway: " & refuseOn

  # An `invariant:` block makes the builder's `return` a validation site
  # (spec §4.7). Splicing would delete that check silently, so the pass
  # refuses the whole type.
  t.src """
type Pct:
  value: int
  invariant:
    value <= 100

fn withDefaults({self: Pct}) -> Pct:
  var s = self
  s ..value {50}
  return s

fn main() -> int:
  var p = {value: 1} Pct
  p ..withDefaults
  return p.value
"""
  let invOn = t.emittedWith("on", @["-O:chain-inplace"])
  if t.phase != pCollect:
    if "tuck_withDefaults(" in invOn:
      t.ok "a type carrying invariants is left alone"
    else:
      t.no "a type carrying invariants is left alone",
           "the validation site was spliced away: " & invOn

  # --- 5. the CLI contract -------------------------------------------------

  t.src wholeValueSrc
  let badFlag = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck",
                            "-o:" & t.curDir / "bad", "--root:" & t.root,
                            "-O:no-such-pass"])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(badFlag)
    if rc != 0 and "no such optimization pass" in outp:
      t.ok "an unknown -O pass name is fatal, not silently ignored"
    else:
      t.no "an unknown -O pass name is fatal, not silently ignored",
           "exit " & $rc & ": " & outp.strip()

  let rep = t.needCmd(@["./tuck", "c", t.curDir / "t.tuck",
                        "-o:" & t.curDir / "rep", "--root:" & t.root,
                        "-O:chain-inplace,report"])
  if t.phase != pCollect:
    let (_, outp) = t.resultOf(rep)
    if "OPTIMIZED" in outp and "withDefaults" in outp:
      t.ok "-O:report names every site it rewrote"
    else:
      t.no "-O:report names every site it rewrote", outp.strip()

  t.finish()
