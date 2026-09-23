## tests/harness.nim — assertions for tuck-driven tests.
##
## Every test here drives the ./tuck BINARY. Nothing imports the compiler as a
## Nim library, which is what the old tests/*.nim did: each of those linked
## compiler/codegen + typecheck + parser, so `nim c` re-ran semantic analysis
## over the whole compiler once per test file. Ten builds of the compiler to
## run nine tests. Now nim builds tuck once, and tuck does the rest.
##
## Ported from tests/lib.sh. The assertion names and their semantics are
## unchanged; only the spelling is (snake_case -> camelCase).
##
##   src """ ... """        write a .tuck file into this test's scratch dir
##   okCheck NAME           `tuck ch` must succeed
##   badCheck NAME, PATTERN `tuck ch` must fail, message matching PATTERN
##   runs NAME, CODE        build and run; exit code must equal CODE
##   emits NAME, PATTERN    emitted Nim must contain PATTERN
##   omits NAME, PATTERN    emitted Nim must NOT contain PATTERN
##   outputs NAME, PATTERN  program stdout/stderr must match PATTERN
##
## NAME labels the case in the report; each call re-uses the file written by
## the preceding `src`.
##
## TWO-PHASE, which tests/lib.sh was not. lib.sh ran each assertion inline:
## fork `tuck ch`, wait, print PASS. That cannot feed a single work pool, so a
## suite body here runs TWICE — once to REGISTER what needs running, once to
## REPORT on what ran. Between the two passes the runner executes every
## registered item from every suite in one pool bounded by the core count.
## The assertions look identical at the call site; `phase` is what differs.

import std/[os, osproc, strutils, strformat, tables, re, streams, monotimes, times]

type
  Verb* = enum
    ## What a work item asks of the toolchain. Ordered cheap-to-expensive:
    ## a check is lex+parse+typecheck, an emit adds codegen, a build adds a
    ## full Nim compile-and-link (~0.85s, by far the most expensive thing a
    ## test does), and a run needs that build to have happened first.
    vCheck, vEmit, vEmitOdin, vEmitD, vBuild, vRun

  Phase* = enum
    pCollect, pReport

  WorkItem* = object
    dir*: string       ## this snippet's scratch dir
    verb*: Verb
    dep*: int          ## index of the item this one needs first; -1 if none
    rc*: int
    output*: string
    done*: bool
    skipped*: bool     ## filtered out by --check/--quick, never attempted
      ## Distinct from `done == false`, which means "its dependency failed".
      ## Assertions must report a skipped item as SKIP, not as a failure —
      ## otherwise a mode that runs fewer items reports a wall of red instead
      ## of a smaller, honest green.

  T* = object
    ## One suite's state. `work` is handed to the runner between passes.
    name*: string
    phase*: Phase
    work*: seq[WorkItem]
    byKey: Table[string, int]   ## (dir, verb) -> index; the dedup table
    rawCmds*: Table[int, seq[string]]  ## work index -> argv, for needCmd
    preps*: Table[int, proc (dir: string) {.closure.}]  ## staging, run before the cmd
    dir*: string                ## the suite's scratch root
    cur*: string                ## current snippet dir — the .tuck written by
                                ## `src` lives at `cur / "t.tuck"`. Exported so
                                ## a suite can re-run the SAME snippet under
                                ## different flags via needCmd, which is how
                                ## fn_size checks that --release promotes its
                                ## report to a failure.
    n: int
    cursor: int                 ## report pass: which registration we are on
    passed*, failed*, open*, skipped*: int
    quiet: bool
    lastOk: bool
    lastSkipped: bool
    bless*: bool
    root*: string               ## project root, for --root:

  SuiteProc* = proc (t: var T) {.nimcall.}

var tuckExe* = "./tuck"

# --- how far down the pipeline this run goes -------------------------------
#
# The cost of a test is decided almost entirely by ONE question: does it invoke
# a BACKEND compiler? `tuck` itself is milliseconds — a full check of a snippet
# is ~2ms — while `nim c` or `odin build` on the emitted code is ~0.5-1s, two
# to three orders of magnitude more. So the useful axis is not "which suites"
# but "how far down the pipeline each assertion goes", which is exactly what
# Verb already records.
#
# maxVerb filters the work pool on that. Every suite still RUNS in every mode;
# the assertions whose verb exceeds the cap report SKIP instead of executing.
# That beats the older suite-level `--quick`, which excluded whole files: the
# `declarations` suite is 27 `badCheck`s and zero runs, all of them ~2ms, yet
# it was classified slow and skipped entirely in the inner loop.
var maxVerb* = vRun   ## default: everything except what needs the Odin toolchain

var quietPasses* = false
  ## `--quiet`: suppress PASS/SKIP lines so a full run's output is short
  ## enough to read without grepping past hundreds of them for the one FAIL
  ## that matters. Counters still increment — only the per-line echo is
  ## skipped — so the final "N passed, M failed" summary is unaffected.
  ## Separate from `T.quiet` above: that one is per-ASSERTION (bugFixed/
  ## bugOpen re-interpreting an expected failure) and silences the outcome
  ## entirely, counters included; this one is session-wide and never hides
  ## a real failure.

# --- reporting -----------------------------------------------------------
#
# `quiet` makes the assertions RECORD their outcome in `lastOk` without
# reporting it — that is how bugFixed/bugOpen re-interpret an assertion whose
# failure is sometimes the expected result.

proc ok*(t: var T, name: string) =
  t.lastOk = true
  t.lastSkipped = false
  if t.quiet: return
  t.passed.inc
  if not quietPasses: echo &"  PASS  {name}"

proc no*(t: var T, name, why: string) =
  t.lastOk = false
  t.lastSkipped = false
  if t.quiet: return
  t.failed.inc
  echo &"  FAIL  {name}\n        {why}"

proc skip*(t: var T, name: string) =
  ## This assertion needed a backend compile the current mode excludes.
  ##
  ## `lastOk = true` so a skipped assertion under `quietly` reads as "nothing
  ## to report" rather than as a reproducing bug — otherwise `--check` would
  ## turn every bugOpen whose assertion needs a run into a phantom OPEN line.
  t.lastOk = true
  t.lastSkipped = true
  if t.quiet: return
  t.skipped.inc
  if not quietPasses:
    echo &"  SKIP  {name} (needs a backend build; run without --check/--quick)"

template quietly*(t: var T, body: untyped) =
  ## Run an assertion for its OUTCOME only, then read it with bugFixed/bugOpen:
  ##
  ##   t.quietly: t.runs("x", 2)
  ##   t.bugFixed "x"
  ##
  ## This is lib.sh's `try`, which is a Nim keyword — hence the name.
  t.quiet = true
  body
  t.quiet = false

# --- snippets ------------------------------------------------------------

proc src*(t: var T, code: string) =
  ## Each snippet gets its own directory so a stale artifact from a previous
  ## case can never satisfy this one.
  ##
  ## Counted with its OWN counter, not pass+fail: assertions run under `tryq`
  ## deliberately do not touch those, so deriving the directory from them made
  ## consecutive cases collide — one case's binary answering another's `runs`.
  t.n.inc
  t.cur = t.dir / &"t{t.n}"
  if t.phase == pCollect:
    createDir(t.cur)
    writeFile(t.cur / "t.tuck", code)

proc srcNamed*(t: var T, fname, code: string) =
  ## Like `src`, but the file gets a specific name — for the cases that import
  ## a sibling module and so care what the importer is called.
  t.n.inc
  t.cur = t.dir / &"t{t.n}"
  if t.phase == pCollect:
    createDir(t.cur)
    writeFile(t.cur / fname, code)

proc addFile*(t: var T, fname, code: string) =
  ## Write an extra file beside the current snippet, without starting a new
  ## case. For multi-module tests.
  if t.phase == pCollect:
    createDir(t.cur.parentDir / t.cur.lastPathPart)
    writeFile(t.cur / fname, code)

proc curDir*(t: T): string = t.cur

# --- the work pool -------------------------------------------------------

proc cmdFor*(t: T, idx: int): seq[string] =
  ## The argv for a work item. Kept as data so the runner can execute these
  ## in one pool rather than each assertion forking for itself.
  if idx in t.rawCmds: return t.rawCmds[idx]
  let it = t.work[idx]
  case it.verb
  of vCheck:    @[tuckExe, "ch", it.dir / "t.tuck", "--root:" & t.root]
  # SEPARATE OUTPUT DIRS per verb. lib.sh pointed `tuck c` and `tuck build` at
  # the same -o: directory, which was safe because a shell script ran them one
  # after another. Here they are independent pool items and CAN run at once —
  # and `tuck c` rewriting t.nim under a `tuck build` that has already linked
  # it left the binary in place but the run reporting exit 0 with no output.
  # A snippet asserted with both `emits` and `runs` hit it every time.
  of vEmit:     @[tuckExe, "c", it.dir / "t.tuck", "-o:" & it.dir / "emit",
                  "--root:" & t.root]
  of vEmitOdin: @[tuckExe, "c", it.dir / "t.tuck", "--odin",
                  "-o:" & it.dir / "odin", "--root:" & t.root]
  of vEmitD:    @[tuckExe, "c", it.dir / "t.tuck", "--dlang",
                  "-o:" & it.dir / "dlang", "--root:" & t.root]
  of vBuild:    @[tuckExe, "build", it.dir / "t.tuck", "-o:" & it.dir / "out",
                  "--root:" & t.root]
  # A RUN is wrapped in `timeout`. Without it one hanging program takes the
  # whole suite with it, and that is not hypothetical — examples/20 hangs
  # under Odin today (issue #28), which is exactly why it is compile-gated
  # and not run-gated. A hang should cost one assertion, not the run.
  #
  # 10s is far above any honest assertion here: the slowest run in the tree
  # is milliseconds, and the seconds in a suite are all BUILD time.
  # `timeout` reports 124, so a hang reads as a distinct failure rather than
  # as an ordinary wrong exit code.
  of vRun:      @["timeout", "10", it.dir / "out" / "t"]

proc need(t: var T, verb: Verb, dep = -1): int =
  ## Register a work item, or reuse one already registered for this snippet.
  ##
  ## This is the `.built` / `.emitted` marker files from lib.sh, as a table.
  ## Their point was that a second assertion against the same source cannot
  ## need a different binary: mangle.sh greps ONE emitted program 19 times and
  ## interface_dispatch 13, and re-emitting for each grep answers a question
  ## already answered.
  let key = t.cur & "\0" & $verb
  if t.phase == pCollect:
    if key in t.byKey: return t.byKey[key]
    # Over the mode's cap: registered so indices stay stable across the two
    # passes, but marked skipped so the pool never launches it and the
    # assertion reports SKIP rather than a failure.
    t.work.add WorkItem(dir: t.cur, verb: verb, dep: dep, rc: 0,
                        skipped: verb > maxVerb)
    result = t.work.high
    t.byKey[key] = result
  else:
    result = t.byKey[key]

proc item(t: T, idx: int): WorkItem = t.work[idx]

proc wasSkipped*(t: T, idx: int): bool = t.work[idx].skipped
  ## Did the mode filter drop this item? Exported because a suite that
  ## registers its OWN commands (needCmd) has to answer it for itself — the
  ## built-in assertions do it internally, but `resultOf` on a skipped item
  ## reports rc 0, which reads as a pass.

proc failedTo(t: T, idx: int): bool =
  ## An item that never ran (because its dependency failed) counts as failed.
  not t.work[idx].done or t.work[idx].rc != 0

proc lastLine(s: string): string =
  let ls = s.strip(leading = false).splitLines()
  if ls.len == 0: "" else: ls[^1]

proc tailLines(s: string, n: int): string =
  let ls = s.strip(leading = false).splitLines()
  ls[max(0, ls.len - n) .. ^1].join("\n")

# --- assertions ----------------------------------------------------------

proc okCheck*(t: var T, name: string) =
  let i = t.need(vCheck)
  if t.phase == pCollect: return
  if not t.failedTo(i): t.ok name
  else: t.no name, "expected a clean check, got: " & lastLine(t.item(i).output)

proc badCheck*(t: var T, name, pattern: string) =
  let i = t.need(vCheck)
  if t.phase == pCollect: return
  let it = t.item(i)
  if not t.failedTo(i):
    t.no name, "expected a type error, but the check passed"
  elif find(it.output, re(pattern)) >= 0:
    t.ok name
  else:
    t.no name, &"wrong error; wanted /{pattern}/, got: " & lastLine(it.output)

proc checkSays*(t: var T, name, pattern: string) =
  ## The check PASSES and its output matches — for diagnostics that report
  ## without failing. `okCheck` cannot see the text and `badCheck` demands a
  ## non-zero exit; a warning-shaped diagnostic is neither.
  let i = t.need(vCheck)
  if t.phase == pCollect: return
  let it = t.item(i)
  if t.failedTo(i):
    t.no name, "expected a clean check, got: " & lastLine(it.output)
  elif find(it.output, re(pattern)) >= 0:
    t.ok name
  else:
    t.no name, &"check passed but said nothing matching /{pattern}/: " &
               lastLine(it.output)

proc checkSilent*(t: var T, name, pattern: string) =
  ## The check passes and says NOTHING matching `pattern` — the other half of
  ## checkSays, for asserting an exemption really is one. Without this, a rule
  ## that stopped firing entirely would look identical to a rule correctly not
  ## firing on the exempt case.
  let i = t.need(vCheck)
  if t.phase == pCollect: return
  let it = t.item(i)
  if t.failedTo(i):
    t.no name, "expected a clean check, got: " & lastLine(it.output)
  elif find(it.output, re(pattern)) >= 0:
    t.no name, &"expected no /{pattern}/, got: " & lastLine(it.output)
  else:
    t.ok name

proc runs*(t: var T, name: string, code: int) =
  let b = t.need(vBuild)
  let r = t.need(vRun, dep = b)
  if t.phase == pCollect: return
  if t.wasSkipped(r): t.skip name; return
  if t.failedTo(b):
    t.no name, "build failed: " & tailLines(t.item(b).output, 2)
    return
  let it = t.item(r)
  if it.rc == code: t.ok name
  else: t.no name, &"exit {it.rc}, want {code}: " & lastLine(it.output)

proc builds*(t: var T, name: string) =
  ## The snippet COMPILES AND LINKS, with no claim about running it.
  ##
  ## For code whose runtime behaviour is not the point, or not reachable yet:
  ## `runs` would force an exit code the program has no meaningful one for,
  ## and `emits` only proves text was produced — not that the host compiler
  ## accepts it, which is where an emitted-code bug actually surfaces.
  let b = t.need(vBuild)
  if t.phase == pCollect: return
  if t.wasSkipped(b): t.skip name; return
  if t.failedTo(b): t.no name, "build failed: " & tailLines(t.item(b).output, 2)
  else: t.ok name

proc outputs*(t: var T, name, pattern: string) =
  ## Reads the run captured by the preceding `runs`. Registering the run here
  ## too would be wrong — `outputs` never builds on its own in lib.sh either.
  let r = t.need(vRun, dep = t.need(vBuild))
  if t.phase == pCollect: return
  if t.wasSkipped(r): t.skip name; return
  if find(t.item(r).output, re(pattern)) >= 0: t.ok name
  else:
    t.no name, &"output did not match /{pattern}/: " & lastLine(t.item(r).output)

proc emittedNim(t: T, i: int): string =
  let p = t.item(i).dir / "emit" / "t.nim"
  if fileExists(p): readFile(p) else: ""

proc emits*(t: var T, name, pattern: string) =
  ## A failed emit is reported AS a failed emit, not as a missing pattern —
  ## otherwise a test whose .tuck source stops compiling silently reads as
  ## "feature absent" forever.
  let i = t.need(vEmit)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedNim(i), re(pattern)) >= 0:
    t.ok name
  else:
    t.no name, &"emitted Nim lacks /{pattern}/"

proc omits*(t: var T, name, pattern: string) =
  ## A failed emit must NOT satisfy "the pattern is absent" — with no output at
  ## all the assertion is vacuous, which is the worse direction of the same bug.
  let i = t.need(vEmit)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedNim(i), re(pattern)) >= 0:
    t.no name, &"emitted Nim contains /{pattern}/ but should not"
  else:
    t.ok name

proc emittedOdin(t: T, i: int): string =
  let p = t.item(i).dir / "odin" / "t.odin"
  if fileExists(p): readFile(p) else: ""

proc emitsOdin*(t: var T, name, pattern: string) =
  ## Same as `emits`, against the Odin backend's output. A failed emit is
  ## reported AS a failed emit: reporting it as "lacks pattern" hid a bug entry
  ## whose own .tuck source did not compile, so it read as open long after the
  ## compiler was fixed.
  let i = t.need(vEmitOdin)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "Odin emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedOdin(i), re(pattern)) >= 0:
    t.ok name
  else:
    t.no name, &"emitted Odin lacks /{pattern}/"

proc omitsOdin*(t: var T, name, pattern: string) =
  ## Same as `omits`, against the Odin backend's output. A failed emit counts as
  ## a failure rather than a vacuous pass.
  let i = t.need(vEmitOdin)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "Odin emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedOdin(i), re(pattern)) >= 0:
    t.no name, &"emitted Odin contains /{pattern}/ but should not"
  else:
    t.ok name

proc emittedD(t: T, i: int): string =
  let p = t.item(i).dir / "dlang" / "t.d"
  if fileExists(p): readFile(p) else: ""

proc emitsD*(t: var T, name, pattern: string) =
  ## Same as `emits`, against the D backend's output. A failed emit is
  ## reported AS a failed emit, never as "lacks pattern" (same lesson).
  let i = t.need(vEmitD)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "D emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedD(i), re(pattern)) >= 0:
    t.ok name
  else:
    t.no name, &"emitted D lacks /{pattern}/"

proc omitsD*(t: var T, name, pattern: string) =
  ## Same as `omits`, against the D backend's output.
  let i = t.need(vEmitD)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "D emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedD(i), re(pattern)) >= 0:
    t.no name, &"emitted D contains /{pattern}/ but should not"
  else:
    t.ok name

proc needD*(t: var T): int =
  ## The D-emission item for the current snippet — the emitted .d, its
  ## modules and tuck_rt.d all land in <dir>/dlang, so a suite can point a
  ## dmd build at it. Mirrors needOdin.
  t.need(vEmitD)

proc findDmd*(): string =
  ## The D compiler, or "" when absent. Same shape as findOdin below.
  result = findExe("dmd")
  if result.len > 0: return
  for c in ["/home/kl/apps/dmd2/linux/bin64/dmd"]:
    if fileExists(c): return c
  return ""

# --- golden emission -----------------------------------------------------
#
# `frozen NAME` asserts the emitted Nim is byte-for-byte what it was when the
# behaviour was last verified BY HAND. No compiling, no running: the same
# source through the same compiler produces the same text, so unchanged text
# is unchanged behaviour.
#
# This replaces `runs NAME CODE` for cases whose point is a runtime fact —
# `/i=` really doing integer division shows up as `a = (a div 4)`, which the
# golden pins exactly. Running proved it once; the text carries it from then on.
# A `tuck build` is ~1.03s against ~0.00s for an emit, and 40 of them were 41s
# of a 69s suite.
#
# WHEN THE DIFF APPEARS, READ IT. It means codegen changed. If the new text is
# better — a real improvement or a new feature — verify the runtime behaviour
# by hand ONCE, then update the golden with --bless. A diff nobody can justify
# is the regression this exists to catch.

proc slugify(s: string): string =
  for c in s:
    if c.isAlphaNumeric: result.add c
    elif result.len == 0 or result[^1] != '-': result.add '-'
  result = result.strip(chars = {'-'})

proc unifiedDiff*(want, got: string, ctx: int): string =
  ## Enough of a diff to name the first divergence. lib.sh shelled out to
  ## `diff -u` and printed lines 4..12; the point is the same — show where it
  ## changed, not the whole file.
  let a = want.splitLines()
  let b = got.splitLines()
  var i = 0
  while i < a.len and i < b.len and a[i] == b[i]: i.inc
  if i == a.len and i == b.len: return ""
  var outp: seq[string]
  outp.add &"first difference at line {i + 1}:"
  for j in max(0, i - 2) ..< min(a.len, i + ctx):
    outp.add (if j >= i: "-" else: " ") & a[j]
  for j in i ..< min(b.len, i + ctx):
    outp.add "+" & b[j]
  outp.join("\n")

proc compareGolden(t: var T, name, ext, got: string) =
  ## Shared bless/compare core for `frozen`/`frozenD`: `got` is already the
  ## fully backend-filtered emitted text, so only the golden's file extension
  ## differs per backend.
  let dir = "tests/golden" / t.name
  let want = dir / (slugify(name) & "." & ext)
  if t.bless:
    createDir(dir)
    writeFile(want, got)
    t.ok name & " (blessed)"
    return
  if not fileExists(want):
    t.no name, "no golden yet — verify the behaviour, then --bless"
    return
  let expected = readFile(want)
  if expected == got: t.ok name
  else: t.no name, "emission changed:\n" & unifiedDiff(expected, got, 8)

proc frozen*(t: var T, name: string) =
  let i = t.need(vEmit)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "emission failed: " & lastLine(t.item(i).output)
    return
  # The runtime import is a path relative to the OUTPUT directory, which is a
  # scratch dir — machine-specific, and no part of what is being asserted.
  #
  # Byte-exact filtering, the way lib.sh's `grep -v` was: split on '\n' and
  # rejoin, rather than splitLines + append '\n' per line. The goldens end in a
  # blank line, and the naive form turned that trailing newline into two — a
  # one-byte diff on every golden in the tree.
  let raw = t.emittedNim(i)
  var keep: seq[string]
  for line in raw.split('\n'):
    if line.startsWith("import ") and line.endsWith("compiler/tuck_rt"): continue
    keep.add line
  t.compareGolden(name, "nim", keep.join("\n"))

proc frozenD*(t: var T, name: string) =
  ## Same as `frozen`, against the D backend's emitted output. D's
  ## `import rt = tuck_rt;` names no path (unlike Nim's machine-relative
  ## `import .../compiler/tuck_rt`), so there is no import line to filter
  ## before comparing.
  let i = t.need(vEmitD)
  if t.phase == pCollect: return
  if t.wasSkipped(i): t.skip name; return
  if t.failedTo(i):
    t.no name, "D emission failed: " & lastLine(t.item(i).output)
    return
  t.compareGolden(name, "d", t.emittedD(i))

# --- known-bug tri-state -----------------------------------------------
#
# A bug entry states the CORRECT behaviour as a real assertion, plus whether
# the compiler does that yet:
#
#   bugFixed NAME     — assertion must hold. If it breaks, it REGRESSED.
#   bugOpen  NAME     — assertion is expected to fail. If it starts passing,
#                       the suite fails and tells you to flip it to bugFixed,
#                       which is how a fix gets locked in.
#
# Both read the outcome of the assertion that ran just before them, so:
#   t.tryq(proc (t: var T) = t.runs("x", 2)); t.bugFixed "x"
# Nothing is ever deleted, so a bug that returns is caught by the test
# written when it was first found.

proc bugFixed*(t: var T, name: string) =
  if t.phase == pCollect: return
  # A skipped assertion is not evidence in either direction.
  if t.lastSkipped: t.skip name & " (regression guard)"; return
  if t.lastOk: t.ok name & " (regression guard)"
  else: t.no name, "REGRESSED — this was fixed and has come back"

proc bugOpen*(t: var T, name: string) =
  if t.phase == pCollect: return
  if t.lastSkipped: t.skip name & " (known bug)"; return
  if t.lastOk:
    t.no name, "NOW PASSING — that is GOOD. Change bugOpen to bugFixed to lock it in."
  else:
    t.open.inc
    echo &"  OPEN  {name} (known bug, still reproduces)"

# --- free-form escapes ---------------------------------------------------
#
# A few suites assert things the DSL does not cover — greping the compiler's
# own source for declared diagnostic codes, counting bug_open lines in the
# suite. They register a raw command and read its result.

proc needOdin*(t: var T): int =
  ## The Odin-emission item for the current snippet, registering it if the
  ## suite has not already asked for one. Lets a suite depend on the emitted
  ## .odin without going through emitsOdin.
  t.need(vEmitOdin)

proc needCmdAfter*(t: var T, argv: seq[string], dep: int,
                   prep: proc (dir: string) {.closure.}, dir: string,
                   verb = vBuild): int =
  ## A command that depends on an earlier item AND needs files staged between
  ## the two. `prep` runs after `dep` succeeds and before this command starts.
  ##
  ## This exists for exactly one shape: `odin build` over a package assembled
  ## from a .odin the pool itself produced. Without the hook the staging would
  ## have to happen in the report pass, which is after every command has
  ## already run.
  ##
  ## Defaults to vBuild BECAUSE of that shape: every caller here is an actual
  ## backend compile or the binary it produced, which is exactly what the
  ## cheap modes exist to skip. Registered as vCheck it would run in `--check`
  ## and cost a second apiece.
  let key = "cmd\0" & argv.join("\0")
  if t.phase == pCollect:
    if key in t.byKey: return t.byKey[key]
    t.work.add WorkItem(dir: dir, verb: verb, dep: dep, rc: 0,
                        skipped: verb > maxVerb)
    result = t.work.high
    t.byKey[key] = result
    t.rawCmds[result] = argv
    t.preps[result] = prep
  else:
    result = t.byKey[key]

proc needCmd*(t: var T, argv: seq[string], verb = vCheck): int =
  ## Register an arbitrary command. Keyed by the command itself, since these
  ## are not tied to a snippet dir.
  ##
  ## `verb` declares how expensive it is, so the mode filter can drop it: an
  ## `odin build` registered as vCheck would run in `--check` and cost a
  ## second, defeating the point of the mode. Default vCheck because most raw
  ## commands here are `./tuck` invocations, which are milliseconds.
  let key = "cmd\0" & argv.join("\0")
  if t.phase == pCollect:
    if key in t.byKey: return t.byKey[key]
    t.work.add WorkItem(dir: "", verb: verb, dep: -1, rc: 0,
                        skipped: verb > maxVerb)
    result = t.work.high
    t.byKey[key] = result
    t.rawCmds[result] = argv
  else:
    result = t.byKey[key]

proc skippedCmd*(t: T, idx: int): bool = t.work[idx].skipped
  ## For suites driving raw commands: report SKIP rather than reading a result
  ## that was never produced.

proc resultOf*(t: T, idx: int): (int, string) =
  (t.work[idx].rc, t.work[idx].output)

# --- suite lifecycle -----------------------------------------------------

proc buildsAllowed*(): bool = maxVerb >= vBuild
  ## Whether the current mode runs backend compiles at all.
  ##
  ## For suites that drive commands through `sh` instead of the pool: `sh`
  ## executes immediately, so no filter can reach it: the suite must ask
  ## before it starts. cli_smoke is the whole reason — it is ~100 sequential
  ## `tuck build` + run steps and dominates a full run, so `--check` and
  ## `--quick` skip it wholesale rather than pretending to filter it.

proc shOnce(argv: seq[string]): tuple[rc: int, output: string, ebadf: string]
           {.gcsafe.} =
  let t0 = getMonoTime()
  let child = startProcess(argv[0], args = argv[1 .. ^1],
                           options = {poUsePath, poStdErrToStdOut})
  # Reading a child's pipe has been seen to fail with EBADF ("Bad file
  # descriptor") intermittently during a full run — twice, never on demand,
  # and with the fd limit at 1M so exhaustion is not it. Unhandled it aborts
  # the ENTIRE run with a stack trace, which is how the first occurrences
  # arrived: no command named, no suite named, nothing to reproduce from.
  #
  # Caught here so the next one identifies itself. NOT swallowed: the item
  # fails, carrying the command and the errno, so a transient is a reported
  # failure rather than a crash and a real breakage still fails.
  var output = ""
  var readFailed = ""
  try:
    output = child.outputStream.readAll()
  except IOError, OSError:
    readFailed = getCurrentExceptionMsg()
  let rc = child.waitForExit()
  child.close()
  {.cast(gcsafe).}:
    if getEnv("TUCK_TEST_PROFILE").len > 0:
      # Beside the pool's lines, marked `sh`: these run outside the pool, so
      # without this the profile would silently miss them.
      let f = open(getEnv("TUCK_TEST_PROFILE") & ".sh", fmAppend)
      f.writeLine $(getMonoTime() - t0).inMilliseconds & "\t" & $rc & "\t" &
                  argv.join(" ")
      f.close()
  (rc, output, readFailed)

proc sh*(argv: seq[string]): tuple[rc: int, output: string] {.gcsafe.} =
  ## Run a command NOW and wait. The pool is for work that is independent;
  ## this is for the sequences — build, run what was built, grep what it
  ## printed — where each step needs the one before. cli_smoke is all of that
  ## shape, and expressing ~100 sequential dependencies as pool edges would
  ## obscure rather than parallelize it.
  ##
  ## RETRIED ONCE ON EBADF, because everything structural has been ruled out.
  ## The failure was hunted on 2026-09-12: it happens with the suite's collect
  ## passes running strictly sequentially and no pool alive, so it is not a
  ## race between our own children; the fd count is flat at 4 across all 40
  ## suites, so it is not a leak; the limit is 1M, so it is not exhaustion;
  ## and `cli_smoke` alone will not reproduce it in six consecutive runs. What
  ## is left is a transient below osproc, and the right answer to a transient
  ## on a freshly spawned child is to spawn it again.
  ##
  ## Narrow on purpose: ONLY a failed READ retries, never a command that ran
  ## and failed. The commands this drives are builds and the programs they
  ## produce, both idempotent. A second EBADF is reported as a failure with
  ## the command and the errno, so a systematic breakage still fails loudly.
  assert argv.len > 0
  var (rc, output, ebadf) = shOnce(argv)
  if ebadf.len == 0: return (rc, output)
  (rc, output, ebadf) = shOnce(argv)
  if ebadf.len == 0: return (rc, output)
  let failRc = if rc == 0: 126 else: rc
  (failRc, "could not read the output of `" & argv.join(" ") & "` TWICE: " &
           ebadf & " (see issue #31)")

const OdinThreads* = "-thread-count:1"
  ## EVERY `odin build` in the suite runs single-threaded.
  ##
  ## Odin's own checker corrupts its heap now and then when threaded:
  ## `malloc(): unaligned tcache chunk detected` (rc 134) or a bare SIGSEGV
  ## (rc 139, no output) from the COMPILER, not from our program. Measured
  ## 2026-09-22 on dev-2026-09:b2354a0 over the recursive_types package that
  ## #31 kept naming: 2 crashes in 190 threaded builds, 0 in 190 with this
  ## flag — and it reproduced with the suite's pool at --jobs:1, so it was
  ## never our concurrency, which is what #31 had concluded. Costs ~40% per
  ## Odin build; a suite that fails one run in eight costs more.

proc findOdin*(): string =
  ## The Odin compiler, or "" if it is not installed. Two suites need it —
  ## member_names for one package, odin_backend for thirty-odd — and both
  ## looked in the same places, so the search lives here.
  result = findExe("odin")
  if result.len > 0: return
  for c in ["/home/kl/apps/Odin/odin", "/opt/odin/odin"]:
    if fileExists(c): return c
  return ""

proc stageOdinPkg*(dir, odinSrc: string) =
  ## Assemble a self-contained Odin package: the emitted .odin as main, plus
  ## the Tuck runtime beside it. `odin build` takes a DIRECTORY, and the
  ## emitted `import "tuckrt"` is relative to it, so the runtime has to sit at
  ## the same relative spot inside the copy.
  removeDir(dir)
  createDir(dir / "tuckrt")
  copyFile(odinSrc, dir / "main.odin")
  for f in walkFiles("compiler/tuckrt/*.odin"):
    copyFile(f, dir / "tuckrt" / f.lastPathPart)
  if fileExists("compiler/tuckrt/minicoro.a"):
    copyFile("compiler/tuckrt/minicoro.a", dir / "tuckrt" / "minicoro.a")
  # An IMPORTED Tuck module emits as a sibling `mod_<name>/` package that the
  # main file imports by relative path, so it has to be staged too. Without
  # this a multi-module program failed here with `import cmp "./mod_cmp"` —
  # the compiler had emitted it correctly and the staging simply left it
  # behind, which reads as a backend bug and is not one.
  for d in walkDirs(odinSrc.parentDir / "mod_*"):
    createDir(dir / d.lastPathPart)
    for f in walkFiles(d / "*.odin"):
      copyFile(f, dir / d.lastPathPart / f.lastPathPart)

# --- the host-acceptance assertion ---------------------------------------
#
# `hostBuilds NAME` asserts that every host compiler available ACCEPTS the
# emitted program, on all three backends. It is strictly weaker than `runs`
# (no exit code, no runtime behaviour) and far stronger than `emits`, which
# matches a regex against generated text and therefore asserts the shape of a
# STRING — not that anything will compile it.
#
# It exists because of the dominant bug class in this compiler: a shape the
# CHECKER permits and an emitter only partly handles. `tuck ch` reports OK,
# the emitted text looks plausible, and the host compiler rejects it, naming
# generated code the author never wrote. Every architectural defect found on
# 2026-09-06 was this: `op: <uninit>(tuck_BinOp)` on Odin, D refusing
# `<uninit>[...]`, and D declaring `TRec_a_b_op_5F99 x = tuck_Ctx(...)`.
# `okCheck` cannot see any of them and neither can `emits`.
#
# It is three legs, not one, because two of the three were backend-specific:
# the Nim backend was accidentally immune (it lets Nim infer the type), so an
# assertion that stopped at Nim would have reported green on both.
#
# Registered at vBuild, so `--check` skips it. Builds dominate the clock,
# which is the whole reason the modes exist.
#
# A missing toolchain skips ITS leg rather than the assertion: reporting SKIP
# because dmd is absent would hide a real Odin failure. The pass message says
# which backends actually ran, so a green line cannot be misread as three.

proc hostRuns*(t: var T, name: string, code: int, pattern = "") =
  ## Build AND RUN on every available backend, asserting the same exit code —
  ## and, when `pattern` is given, that each one's output matches it.
  ##
  ## `hostBuilds` proves the three COMPILE the emitted code; nothing proved
  ## they then BEHAVE the same. That gap is how the resource registry came to
  ## abort with SIGABRT on D and exit 1 on the other two for one program, with
  ## a message two of the three had thrown the detail out of (issue #54) —
  ## caught by hand, not by the suite. The project rule is that runtime
  ## characteristics do not depend on the backend, so it needs an assertion.
  ##
  ## Output is matched against the combined streams: a diagnostic of this kind
  ## goes to stderr, and which stream it lands on is not the thing under test.
  let nimB = t.need(vBuild)
  let nimR = t.need(vRun, dep = nimB)
  let odinExe = findOdin()
  let dmdExe = findDmd()

  var odinR = -1
  if odinExe.len > 0:
    let e = t.needOdin()
    let proj = t.curDir / "odinpkg"
    let src = t.curDir / "odin" / "t.odin"
    let b = t.needCmdAfter(@[odinExe, "build", proj, "-o:none", OdinThreads,
                             "-out:" & proj / "prog"], e,
                           proc (dir: string) = stageOdinPkg(dir, src), proj)
    odinR = t.needCmdAfter(@["timeout", "10", proj / "prog"], b,
                           proc (dir: string) = discard, proj, verb = vRun)
  var dR = -1
  if dmdExe.len > 0:
    let e = t.needD()
    let dir = t.curDir / "dlang"
    let b = t.needCmdAfter(@[dmdExe, "-i", "-I" & dir, dir / "t.d",
                             dir / "minicoro.a", "-of=" & dir / "prog"],
                           e, proc (dir: string) = discard, dir)
    dR = t.needCmdAfter(@["timeout", "10", dir / "prog"], b,
                        proc (dir: string) = discard, dir, verb = vRun)
  if t.phase == pCollect: return
  if t.wasSkipped(nimR): t.skip name; return

  var ran: seq[string]
  for (label, idx) in [("nim", nimR), ("odin", odinR), ("d", dR)]:
    if idx < 0 or t.skippedCmd(idx): continue
    let (rc, output) = t.resultOf(idx)
    if rc != code:
      t.no name, label & " exited " & $rc & ", wanted " & $code &
                 (if output.strip == "": " (NO OUTPUT)"
                  else: ": " & tailLines(output, 2))
      return
    if pattern != "" and find(output, re(pattern)) < 0:
      t.no name, label & " did not match /" & pattern & "/: " &
                 tailLines(output, 2)
      return
    ran.add label
  if ran.len == 0: t.skip name
  else: t.ok name & "  [" & ran.join(", ") & "]"

proc hostPeakRss*(t: var T, name: string, budgetKB: int) =
  ## Build and run on EVERY available backend, asserting each exits 0 and
  ## stays under a memory budget.
  ##
  ## Nothing else in the suite measures memory, and that is how the Odin
  ## backend came to leak every heap value it copied — 75 KB per message,
  ## OOM-killed at 13.6 GB — while passing every assertion in the tree
  ## (KNOWN-BUGS-EVENTS.md EV-12, issue #77). An allocation bug is invisible
  ## to `okCheck`, invisible to a regex over emitted text, and invisible to
  ## an exit code: the program is CORRECT, it simply cannot survive a large
  ## input.
  ##
  ## THREE LEGS, NOT ONE, and not as a matter of thoroughness. The backend
  ## that leaks is the one with no collector; Nim has ARC and D has a GC, so
  ## a Nim-only budget passes at 1.6 MB while Odin sits at 482 MB on the same
  ## program. A one-backend memory assertion cannot observe the only bug of
  ## this class the tree has ever had.
  ##
  ## Budgets are meant to be LOOSE. This is not a performance assertion: each
  ## should sit well above what a non-leaking backend needs and well below
  ## what a leaking one reaches, so the gap does the work and ordinary
  ## allocator variation does not. A budget that trips on a 2x wobble gets
  ## switched off within a month.
  ##
  ## Measurement is `tests/peak_rss.sh` (polls VmHWM); its exit 90 means
  ## over budget, and any other non-zero is the program's own.
  let measure = t.root / "tests" / "peak_rss.sh"
  let noPrep = proc (dir: string) = discard
  let nimB = t.need(vBuild)
  let nimR = t.needCmdAfter(@[measure, $budgetKB, t.curDir / "out" / "t"],
                            nimB, noPrep, t.curDir, verb = vRun)
  let odinExe = findOdin()
  let dmdExe = findDmd()

  var odinR = -1
  if odinExe.len > 0:
    let e = t.needOdin()
    let proj = t.curDir / "odinpkg"
    let src = t.curDir / "odin" / "t.odin"
    let b = t.needCmdAfter(@[odinExe, "build", proj, "-o:none", OdinThreads,
                             "-out:" & proj / "prog"], e,
                           proc (dir: string) = stageOdinPkg(dir, src), proj)
    odinR = t.needCmdAfter(@[measure, $budgetKB, proj / "prog"], b,
                           noPrep, proj, verb = vRun)
  var dR = -1
  if dmdExe.len > 0:
    let e = t.needD()
    let dir = t.curDir / "dlang"
    let b = t.needCmdAfter(@[dmdExe, "-i", "-I" & dir, dir / "t.d",
                             dir / "minicoro.a", "-of=" & dir / "prog"],
                           e, noPrep, dir)
    dR = t.needCmdAfter(@[measure, $budgetKB, dir / "prog"], b,
                        noPrep, dir, verb = vRun)
  if t.phase == pCollect: return
  if t.wasSkipped(nimR): t.skip name; return

  var ran: seq[string]
  for (label, idx) in [("nim", nimR), ("odin", odinR), ("d", dR)]:
    if idx < 0 or t.skippedCmd(idx): continue
    let (rc, output) = t.resultOf(idx)
    let peak = strip(lastLine(output))
    if rc == 90:
      t.no name, label & " over budget: " & peak
      return
    if rc != 0:
      t.no name, label & " exited " & $rc &
                 (if output.strip == "": " (NO OUTPUT)"
                  else: ": " & tailLines(output, 2))
      return
    ran.add label & " " & peak.replace("peakRSS=", "").split(" ")[0]
  if ran.len == 0: t.skip name
  else: t.ok name & "  [" & ran.join(", ") & "]"

proc hostBuilds*(t: var T, name: string) =
  let nimB = t.need(vBuild)
  let odinExe = findOdin()
  let dmdExe = findDmd()

  var odinB = -1
  if odinExe.len > 0:
    let e = t.needOdin()
    let proj = t.curDir / "odinpkg"
    let src = t.curDir / "odin" / "t.odin"
    odinB = t.needCmdAfter(@[odinExe, "build", proj, "-o:none", OdinThreads,
                             "-out:" & proj / "prog"], e,
                           proc (dir: string) = stageOdinPkg(dir, src), proj)
  var dB = -1
  if dmdExe.len > 0:
    let e = t.needD()
    let dir = t.curDir / "dlang"
    dB = t.needCmdAfter(@[dmdExe, "-i", "-I" & dir, dir / "t.d",
                          dir / "minicoro.a", "-of=" & dir / "prog"],
                        e, proc (dir: string) = discard, dir)
  if t.phase == pCollect: return
  if t.wasSkipped(nimB): t.skip name; return

  var ran: seq[string]
  if t.failedTo(nimB):
    t.no name, "nim rejected the emitted code: " &
               tailLines(t.item(nimB).output, 2)
    return
  ran.add "nim"
  for (label, idx) in [("odin", odinB), ("d", dB)]:
    if idx < 0: continue
    if t.skippedCmd(idx): continue
    let (rc, output) = t.resultOf(idx)
    if rc != 0:
      # The rc is in the message on purpose. A host compiler that REJECTS a
      # program prints a diagnostic; one that exits non-zero with an EMPTY
      # buffer was killed, or its output was lost on the way back. Every
      # occurrence of the recursive_types flake (issue #31) has looked like
      # the second and thrown the number away, leaving nothing to tell the
      # two apart.
      let detail = if output.strip() == "": "NO OUTPUT"
                   else: tailLines(output, 2)
      t.no name, label & " rejected the emitted code (rc=" & $rc & "): " &
                 detail
      return
    ran.add label
  t.ok name & "  [" & ran.join(", ") & "]"

proc rewind*(t: var T) =
  ## Reset the per-body cursors between the collect and report passes. The
  ## work items and their results stay; only the position in the body resets.
  t.n = 0
  t.cur = ""
  t.quiet = false
  t.lastOk = true

proc finish*(t: var T) =
  if t.phase == pCollect: return
  if t.open > 0: echo &"open bugs: {t.open}"
  # The `.sh` suffix is kept deliberately: run-all-tests.sh grepped for this
  # exact shape, and so does tests/end_to_end.sh's MISSING-FEATURES count.
  # Renaming it would be a second migration for no gain.
  let skipNote = if t.skipped > 0: &", {t.skipped} skipped" else: ""
  echo &"{t.name}.sh: {t.passed} passed, {t.failed} failed{skipNote}"
