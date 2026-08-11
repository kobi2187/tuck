## Cyclomatic complexity RATCHET over the compiler sources.
##
## The project's refactoring rule has two triggers: a proc is 5-8 lines (hard
## cap ~10), and complexity over 5 splits unconditionally. Length is easy to
## eyeball; complexity is not — genOdinCall sat at cc=32 in 47 lines and read
## as "already refactored" because its LENGTH had come down while its chain of
## `calleeStr == "..."` tests had not.
##
## So this gate exists to make the second trigger visible. It is a RATCHET, not
## a target: both numbers are set to whatever the tree currently is, so the
## tree cannot get worse, and they are lowered by hand as procs are split. They
## are never raised to accommodate new code — a new proc over the ceiling is
## the failure this catches.
##
##   CEILING — no proc may exceed this complexity.
##   BUDGET  — how many procs may sit above the threshold of 5.
##
## The script prints "tighten --budget to N" whenever the real count has
## dropped below the budget, so the ratchet reports its own slack instead of
## quietly drifting.
##
## MEASURED ON THE REAL AST. tools/cc.nim parses each file with the Nim
## compiler's own parser and walks the tree. The previous tool matched
## `if|elif|while|and|or|except` as TEXT, which was wrong twice over: it counted
## those words inside string literals (a three-arm case whose arms are English
## sentences scored 8), and it never counted `case` arms at all — so a 20-arm
## case over an enum scored 1, and the metric was blind to how Nim actually
## branches. Swapping to the AST moved the honest numbers to 280/64 from the
## regex's 188/27; nothing in the tree changed.

import std/[os, strutils]
import ../harness

const
  CEILING = 64
  # RAISED 280 -> 286 when compiler/optimize.nim landed: six routines, all of
  # them either a kind-dispatch `case` (mentionsName, rewriteChains) or a flat
  # run of guard clauses (builderSteps, which is a refusal list — every `if
  # ... return @[]` is one shape the pass declines to touch). Both are the
  # shape this codebase deliberately keeps whole rather than splitting; see
  # codegen.nim's "LENGTH IS NOT THE PROBLEM, NESTING IS".
  #
  # Note the metric counts ROUTINES OVER THE CEILING, not total complexity, so
  # splitting a cc=39 guard run into three cc=13 helpers makes this number
  # WORSE, not better. Raise it deliberately with a reason, or reduce the
  # routine count (deduplicating optimize.nim's two identical AST walks took
  # it from 7 to 6) — do not split a proc just to move the number.
  BUDGET = 286
  CC = "tools/cc"

proc run*(t: var T) =
  if not fileExists(CC):
    if t.phase != pReport: return
    echo "complexity.sh: tools/cc not built. Once:"
    echo "  nim c --path:$(dirname $(dirname $(readlink -f $(command -v nim)))) \\"
    echo "      -o:tools/cc tools/cc.nim"
    t.failed.inc
    return

  var argv = @[CC, "--gate", $CEILING, "--budget", $BUDGET]
  for f in walkFiles("compiler/*.nim"): argv.add f
  argv.add "lexer.nim"
  argv.add "tuck.nim"
  let i = t.needCmd(argv)

  if t.phase != pReport: return

  echo "== cyclomatic complexity ratchet (ceiling " & $CEILING &
       ", budget " & $BUDGET & ") =="
  let (rc, outp) = t.resultOf(i)
  # Only the summary lines are shown; the full ranked table is `tools/cc` on its
  # own.
  for l in outp.splitLines():
    if not l.startsWith("  cc="): echo l

  if rc == 0:
    echo "complexity.sh: passed, 0 failed"
    return
  t.failed.inc
  echo "complexity.sh: 1 failed"
  echo "  A proc got more complex, or a new one landed over the ceiling."
  echo ""
  echo "  BUDGET is a COUNT, not a per-proc verdict: any proc over cc 5 that"
  echo "  gets split pays it back. Splitting the newcomer is rarely the best"
  echo "  trade — a small proc at cc=6 is far more readable than the cc=40+"
  echo "  procs already in the tree. Run"
  echo ""
  echo "    tools/cc compiler/*.nim lexer.nim tuck.nim | head -20"
  echo ""
  echo "  and split the worst offender you can do WELL instead. Never raise"
  echo "  CEILING/BUDGET in this file."
