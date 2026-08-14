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
##   DEBT    — sum of (cc - 5) over every proc above 5. Total, not headcount.
##   HEAVY   — how many procs may sit at cc>=15, where reading really suffers.
##
## DEBT and HEAVY replaced a plain COUNT of procs over 5. The count treated a
## cc=6 helper and a cc=53 monster as equal debt, so it fired on the 64 procs
## sitting one over the line while staying silent about the tail — and it
## PUNISHED splitting a monster, since three procs over 5 score worse than one
## at 53. The goal was always "small readable procs"; these two measure that,
## the count measured headcount.
##
## The script prints "tighten --debt/--heavy to N" whenever the real figure has
## dropped below the gate, so the ratchet reports its own slack instead of
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
  # DEBT and HEAVY replaced a plain COUNT of routines over 5, which was the
  # wrong gate and had been quietly punishing good code.
  #
  # The count weighted every routine the same, so a cc=6 helper — one guard
  # plus a short case — was the same unit of debt as a cc=53 monster. Two
  # consequences, both real in this tree:
  #
  #   * it fired on good code: 64 routines sit at exactly cc=6, one over the
  #     line, and nearly all of them are fine as they are;
  #   * it PUNISHED the fix. Splitting genType (cc=53, then the worst proc
  #     here) into three readable procs RAISED the count by two, because three
  #     routines over 5 score worse than one at 53. The gate was rewarding
  #     leaving monsters intact — the opposite of its purpose.
  #
  # DEBT sums how far each routine exceeds 5, so the arithmetic finally
  # matches the intent: splitting 53 into 8+7+6 moves debt 48 -> 6, and a new
  # small helper costs 1. HEAVY counts only routines at cc>=15 (this tree's
  # p90) — the ones where complexity actually costs a reader. Together: "the
  # tail is shrinking", without taxing every small helper.
  #
  # Both are still RATCHETS. tools/cc prints "tighten --debt/--heavy to N"
  # whenever the real figure is below the gate, so slack reports itself.
  # Raising either needs a reason in this comment.
  #
  # 1953 -> 1963 (2026-08-14): the `<uninit>` field analysis. A new rule that
  # every write path and the single field-read site must honour cannot be free
  # in branch count. What was extractable WAS extracted first — the diagnostic
  # out of asPlainField, the record rebuild out of clearUninit, and
  # constructedType split three ways (13 -> 6) — taking the cost from 22 to
  # 10. The remainder is the rule itself: two more arms in checkChainStep,
  # one guard each in synthReassign, anyUninit and clearUninit.
  #
  # 1963 -> 1964 (same day): TK-TY16's arm in the `explain` table. A registry
  # dispatch, so +1 for the whole table rather than per code — every new
  # diagnostic costs this, and diagnostics.nim's suite requires the arm.
  #
  # 1964 -> 1476, HEAVY 60 -> 45 (2026-08-14): NOT a code change — tools/cc
  # stopped charging for PURE DISPATCH ARMS. An `of` arm with no decision of
  # its own is a lookup-table entry written in control-flow syntax, and
  # counting one apiece made a 21-kind AST dispatch outscore genuinely knotty
  # code. Nearly 500 of the tree's measured debt was tables. The exemption is
  # measured, not assumed: an arm that loops, tests or short-circuits still
  # counts in full (tools/cc.nim isDispatchArm). What now tops the ranking —
  # lowerExpr at 42, scanNext at 38 — is real work, which is the point.
  #
  # 1476 -> 1487 (2026-08-14): mutators fill only the fields they PROVABLY
  # assign, which needs a write-side scan of the callee (collectFieldWrites
  # and its three shape helpers). The alternative was the previous behaviour —
  # any `..fn` clears every hole — which is unsound in the direction that
  # matters: it hands back a "filled" field the mutator never touched.
  #
  # 1487 -> 1424, HEAVY 45 -> 42 (2026-08-14): a complexity pass. Four procs
  # split along boundaries their own comments already described —
  # builderSteps 39 -> 14/11/10, checkRegistry 34 -> four rules, lowerExpr
  # 42 -> 12/10/6 (its ~20 recursion arms became ast.children), mangleExpr
  # 32 -> 22 (the same, minus the three arms that carry a scoping rule).
  # Behaviour-preserving: emitted output for examples/ is byte-identical
  # throughout, which is the real check for the lowering and mangling ones.
  DEBT = 1424
  HEAVY = 42
  CC = "tools/cc"

proc run*(t: var T) =
  if not fileExists(CC):
    if t.phase != pReport: return
    echo "complexity.sh: tools/cc not built. Once:"
    echo "  nim c --path:$(dirname $(dirname $(readlink -f $(command -v nim)))) \\"
    echo "      -o:tools/cc tools/cc.nim"
    t.failed.inc
    return

  var argv = @[CC, "--gate", $CEILING, "--debt", $DEBT, "--heavy", $HEAVY]
  for f in walkFiles("compiler/*.nim"): argv.add f
  argv.add "lexer.nim"
  argv.add "tuck.nim"
  let i = t.needCmd(argv)

  if t.phase != pReport: return

  echo "== cyclomatic complexity ratchet (ceiling " & $CEILING &
       ", debt " & $DEBT & ", heavy " & $HEAVY & ") =="
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
  echo "  A proc got more complex, or a heavy new one landed."
  echo ""
  echo "  DEBT is the sum of (cc - 5) over every proc above 5, so it rewards"
  echo "  what you actually want: splitting a cc=53 proc into 8+7+6 moves debt"
  echo "  48 -> 6. A genuinely-needed small helper at cc=6 costs 1, which is"
  echo "  the right price. HEAVY counts procs at cc>=15 — the ones that hurt"
  echo "  to read. Neither punishes a good split. Run"
  echo ""
  echo "    tools/cc compiler/*.nim lexer.nim tuck.nim | head -20"
  echo ""
  echo "  and split the worst offender you can do WELL. If a new proc really"
  echo "  needs its complexity (a dispatch `case` over an enum is dispatch,"
  echo "  not complexity), raise the number here WITH the reason — but check"
  echo "  first whether paying it down elsewhere is the better trade."
