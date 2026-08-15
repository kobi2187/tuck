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
##   HEAVY   — how many procs may sit at cc>=15, where reading really suffers.
##
## ONLY THE TOP OFFENDERS ARE GATED. Both numbers are ORDER STATISTICS — the
## max, and the count above roughly p90 — which is what makes them honest about
## a growing codebase: adding 300 small helpers moves neither, and one new
## monster moves both.
##
## A third gate, DEBT (the sum of cc-5 over every proc above 5), was dropped on
## 2026-08-15. A sum grows with SIZE, not with quality — a 2x bigger compiler
## of identical quality doubles it, so it cannot tell "worse" from "more". It
## also moved 1964 -> 1476 on a change to the measuring tool's own counting
## rule, a third of the total, with the tree untouched. And it taxed
## correctness: a bug fix needing one honest extra branch failed the gate until
## something unrelated was refactored to pay for it, which is the same perverse
## incentive the plain COUNT gate had before it. tools/cyc still PRINTS debt, so
## the trend stays visible; nothing fails on it.
##
## (The COUNT gate that preceded both treated a cc=6 helper and a cc=53 monster
## as equal, so it fired on the 64 procs one over the line while staying silent
## about the tail — and it PUNISHED splitting a monster, since three procs over
## 5 score worse than one at 53.)
##
## The script prints "tighten --heavy to N" whenever the real figure has
## dropped below the gate, so the ratchet reports its own slack instead of
## quietly drifting.
##
## MEASURED ON THE REAL AST. tools/cyc.nim parses each file with the Nim
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
  # CEILING: no routine may exceed this. 64 -> 22 (2026-08-15) — it had been
  # set when scanNext sat at 38 and nothing has approached it since, so it was
  # gating nothing. Now one over the current worst.
  CEILING = 22

  # HEAVY: how many routines may sit at cc>=15 — this tree's p90, and the point
  # where a `case` stops being dispatch and starts being a thing you trace.
  # A RATCHET: set to whatever the tree currently is, lowered by hand as procs
  # are split, never raised to accommodate new code. tools/cyc prints
  # "tighten --heavy to N" whenever the real figure is below the gate, so slack
  # reports itself. Raising it needs a reason written here.
  #
  # 60 -> 45 (2026-08-14): NOT a code change — tools/cyc stopped charging for
  # PURE DISPATCH ARMS. An `of` arm with no decision of its own is a
  # lookup-table entry written in control-flow syntax, and counting one apiece
  # made a 21-kind AST dispatch outscore genuinely knotty code. The exemption
  # is measured, not assumed: an arm that loops, tests or short-circuits still
  # counts in full (tools/cyc.nim isDispatchArm).
  #
  # 45 -> 42 (2026-08-14): four procs split along boundaries their own comments
  # already described — builderSteps 39 -> 14/11/10, checkRegistry 34 -> four
  # rules, lowerExpr 42 -> 12/10/6 (its ~20 recursion arms became
  # ast.children), mangleExpr 32 -> 22.
  # 42 -> 40: synthCall split into asRestructuringBuiltin + asNamedCallee
  # (27 -> 10/9), and sameType's four "same length, then pairwise" arms
  # collapsed onto two helpers (23 -> 9).
  # 40 -> 39: raisedEventsIn walks ast.children instead of ten hand-listed
  # kinds plus `else: discard`.
  # 39 -> 33: the ast.children sweep. Every hand-rolled Expr walk in the tree
  # now uses the iterator. Four of those walks had a silent gap; two were real
  # bugs (EV-4, and the pointer-return tkFunc case).
  # 33 -> 32: scanNext, then the tree's worst proc at cc=38, split into its
  # four stages and the multi-char operator nest turned into a table.
  #
  # 32 -> 28 (2026-08-15), the pass that also dropped the DEBT gate:
  #   * ast.childDecls / ast.ownExprs — the Decl half of ast.children. clearIds
  #     and assignIds(Decl) were the SAME traversal written twice, identical
  #     arms differing only in the action; both are now two lines. 16/16 -> 0.
  #   * toString 29 -> 8: two operator spelling tables lifted out as opStr(),
  #     the three hand-rolled comma-joins replaced by listToString, and the
  #     four optional-payload `if`s by optToString.
  #   * mangleModuleWith 22 -> 9: one dispatch doing two independent jobs
  #     (mangle the types a decl mentions, mangle the expressions it owns)
  #     split into mangleDeclTypes + mangleDeclRefs, the latter reaching bodies
  #     and members through ownExprs/childDecls. Emitted output for examples/
  #     is byte-identical, which is the real check for a mangling change.
  #
  # 28 -> 26 (2026-08-15), the duplication pass. ast.children gains a Type
  # overload and ast.ownTypes joins childDecls/ownExprs, so the four walks a
  # Decl needs are written once each:
  #   * resolveTypeRefs 17 -> 3 and mangleType 17 -> 3 were the SAME structural
  #     walk over Type, differing only in the action at tkNamed. They had
  #     already drifted — mangleType ended in `else: discard` where the other
  #     listed tkEffect.
  #   * resolveDeclTypeRefs 25 -> 3, which was ownTypes + childDecls recursion
  #     spelled out over 21 kinds; dkInterface and dkWhen had gone missing from
  #     it until an earlier `else: discard` removal surfaced them.
  #   * assignIds(Expr) 20 -> 6, the last hand-rolled Expr walk. Now matches
  #     clearIds exactly: one exkChain arm for the step ids, then children.
  HEAVY = 26
  CC = "tools/cyc"

proc run*(t: var T) =
  if not fileExists(CC):
    if t.phase != pReport: return
    echo "complexity.sh: tools/cyc not built. Once:"
    echo "  nim c --path:$(dirname $(dirname $(readlink -f $(command -v nim)))) \\"
    echo "      -o:tools/cyc tools/cyc.nim"
    t.failed.inc
    return

  var argv = @[CC, "--gate", $CEILING, "--heavy", $HEAVY]
  for f in walkFiles("compiler/*.nim"): argv.add f
  argv.add "lexer.nim"
  argv.add "tuck.nim"
  let i = t.needCmd(argv)

  if t.phase != pReport: return

  echo "== cyclomatic complexity ratchet (ceiling " & $CEILING &
       ", heavy " & $HEAVY & ") =="
  let (rc, outp) = t.resultOf(i)
  # Only the summary lines are shown; the full ranked table is `tools/cyc` on its
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
  echo "  CEILING is the worst proc in the tree; HEAVY counts the procs at"
  echo "  cc>=15 — the ones that actually hurt to read. Both are order"
  echo "  statistics, so a pile of small helpers costs nothing and one new"
  echo "  monster costs immediately. Neither punishes a good split. Run"
  echo ""
  echo "    tools/cyc compiler/*.nim lexer.nim tuck.nim | head -20"
  echo ""
  echo "  and split the worst offender you can do WELL. If a new proc really"
  echo "  needs its complexity (a dispatch `case` over an enum is dispatch,"
  echo "  not complexity), raise the number here WITH the reason — but check"
  echo "  first whether paying it down elsewhere is the better trade."
