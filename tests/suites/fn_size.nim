## THE PER-FUNCTION SIZE BUDGET — compiler/complexity.nim.
##
## Two limits on every `fn` and `task` body: cyclomatic complexity (default 6)
## and source lines (default 8).
##
## THIS PASS DOES NOT FAIL FAST, unlike every other stage. Each function's
## numbers are independent, so the whole module is measured before anything is
## decided and the output is a RANKED list, worst first. A normal build REPORTS
## it; only `--release` fails on it. That is why the assertions below are
## `checkSays` (passes, and says this) rather than `badCheck`.
##
## NOT THE SAME THING as tests/suites/complexity.nim. That one is a ratchet over
## the compiler's OWN Nim sources, measured by tools/cc.nim; this one is the
## rule the compiler enforces on the TUCK code it is given.
##
## WHAT THE INTERESTING CASES ARE:
##
##   a flat 12-line fn      -> complexity 1, still reported (lines)
##   a 7-branch fn          -> 8 lines, still reported (complexity)
##   a 10-arm match         -> SILENT, however long
##   a 12-variant type      -> SILENT, never measured at all
##   three offenders        -> ranked by how far over, worst first
##
## The match case is the one to protect. Tuck REQUIRES exhaustive matching
## (dcTyNotExhaustive), so charging per arm would have the compiler demand a
## complete table with one rule and fine the author for its length with
## another — pressure toward a non-exhaustive `if` chain, which is the weaker
## construct. So the construct itself costs nothing; only what the arms DO is
## counted. A regression here would not look like a crash, it would look like
## the compiler quietly discouraging correct code.
import ../harness
import std/[strutils, os]

proc run*(t: var T) =
  # --- under budget: nothing is said ----------------------------------------

  t.src """
fn classify({n: int}) -> int:
  if n > 100:
    return 2
  if n > 10:
    return 1
  return 0

fn main() -> void:
  return
"""
  t.checkSilent "under both limits, no report", "TK-CX"

  # --- complexity ------------------------------------------------------------

  t.src """
fn tangled({n: int}) -> int:
  if n > 1:
    return 1
  if n > 2:
    return 2
  if n > 3:
    return 3
  if n > 4:
    return 4
  if n > 5:
    return 5
  if n > 6:
    return 6
  if n > 7:
    return 7
  return 0

fn main() -> void:
  return
"""
  t.checkSays "complexity over the limit", "TK-CX01"

  # --- lines -----------------------------------------------------------------
  #
  # Complexity 1 — this fn branches not at all and is still too long. It is the
  # case the line limit exists for, and the reason one number is not enough.

  t.src """
fn wide() -> int:
  let a = 1
  let b = 2
  let c = 3
  let d = 4
  let e = 5
  let f = 6
  let g = 7
  let h = 8
  let i = 9
  let j = 10
  return a

fn main() -> void:
  return
"""
  t.checkSays "lines over the limit", "TK-CX02"

  # --- the tabular exemption -------------------------------------------------
  #
  # 10 arms over 20 lines: over BOTH limits if arms were counted, silent
  # because they are a table. See the header note on why this matters.

  t.src """
type Color:
  | Red
  | Green
  | Blue
  | Cyan
  | Magenta
  | Yellow
  | Black
  | White
  | Gray
  | Pink

fn code({c: Color}) -> int:
  match c:
    Red:
      return 1
    Green:
      return 2
    Blue:
      return 3
    Cyan:
      return 4
    Magenta:
      return 5
    Yellow:
      return 6
    Black:
      return 7
    White:
      return 8
    Gray:
      return 9
    Pink:
      return 10

fn main() -> void:
  return
"""
  t.checkSilent "a long match is a table, not a long fn", "TK-CX"

  # --- declarations are never measured ---------------------------------------
  #
  # A type is a vocabulary. It has no paths through it and no body to split, so
  # neither number means anything there.

  t.src """
type Big:
  | A
  | B
  | C
  | D
  | E
  | F
  | G
  | H
  | I
  | J
  | K
  | L

type Wide:
  f1: int
  f2: int
  f3: int
  f4: int
  f5: int
  f6: int
  f7: int
  f8: int
  f9: int
  f10: int
  f11: int
  f12: int

fn main() -> void:
  return
"""
  t.checkSilent "types and enums are exempt", "TK-CX"

  # --- ranking, and --release ------------------------------------------------
  #
  # Three offenders at different severities. The ORDER is the deliverable: a
  # report that leads with the 1-line-over fn buries the 22-line one, which is
  # the whole reason this pass measures everything before saying anything.

  t.src """
fn mild() -> int:
  let a = 1
  let b = 2
  let c = 3
  let d = 4
  let e = 5
  let f = 6
  let g = 7
  return a

fn severe() -> int:
  let a = 1
  let b = 2
  let c = 3
  let d = 4
  let e = 5
  let f = 6
  let g = 7
  let h = 8
  let i = 9
  let j = 10
  let k = 11
  let l = 12
  let m = 13
  let n = 14
  let o = 15
  let p = 16
  let q = 17
  let r = 18
  let s = 19
  let u = 20
  return a

fn main() -> void:
  return
"""
  t.checkSays "all offenders reported at once, not just the first", "severe"

  let ranked = t.needCmd @["./tuck", "ch", t.cur / "t.tuck", "--root:" & t.root]
  let rel = t.needCmd @["./tuck", "ch", t.cur / "t.tuck", "--root:" & t.root,
                        "--release"]
  if t.phase == pReport:
    # worst first: `severe` (14 over) must precede `mild` (1 over).
    let (_, out1) = t.resultOf(ranked)
    let iSevere = out1.find("severe")
    let iMild = out1.find("mild")
    if iSevere >= 0 and iMild >= 0 and iSevere < iMild:
      t.ok "worst offender is listed first"
    else:
      t.no "worst offender is listed first",
           "severe@" & $iSevere & " mild@" & $iMild & " in: " & out1.strip

    # Same measurement, different consequence: --release must FAIL.
    let (rc2, out2) = t.resultOf(rel)
    if rc2 == 0:
      t.no "--release fails on an over-budget fn", "exit 0, want non-zero"
    elif "OVER BUDGET" in out2:
      t.ok "--release fails on an over-budget fn"
    else:
      t.no "--release fails on an over-budget fn", "got: " & out2.strip
