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

import std/[os, osproc, strutils, strformat, tables, re]

type
  Verb* = enum
    ## What a work item asks of the toolchain. Ordered cheap-to-expensive:
    ## a check is lex+parse+typecheck, an emit adds codegen, a build adds a
    ## full Nim compile-and-link (~0.85s, by far the most expensive thing a
    ## test does), and a run needs that build to have happened first.
    vCheck, vEmit, vEmitOdin, vBuild, vRun

  Phase* = enum
    pCollect, pReport

  WorkItem* = object
    dir*: string       ## this snippet's scratch dir
    verb*: Verb
    dep*: int          ## index of the item this one needs first; -1 if none
    rc*: int
    output*: string
    done*: bool

  T* = object
    ## One suite's state. `work` is handed to the runner between passes.
    name*: string
    phase*: Phase
    work*: seq[WorkItem]
    byKey: Table[string, int]   ## (dir, verb) -> index; the dedup table
    rawCmds*: Table[int, seq[string]]  ## work index -> argv, for needCmd
    preps*: Table[int, proc (dir: string) {.closure.}]  ## staging, run before the cmd
    dir*: string                ## the suite's scratch root
    cur: string                 ## current snippet dir
    n: int
    cursor: int                 ## report pass: which registration we are on
    passed*, failed*, open*: int
    quiet: bool
    lastOk: bool
    bless*: bool
    root*: string               ## project root, for --root:

  SuiteProc* = proc (t: var T) {.nimcall.}

var tuckExe* = "./tuck"

# --- reporting -----------------------------------------------------------
#
# `quiet` makes the assertions RECORD their outcome in `lastOk` without
# reporting it — that is how bugFixed/bugOpen re-interpret an assertion whose
# failure is sometimes the expected result.

proc ok*(t: var T, name: string) =
  t.lastOk = true
  if t.quiet: return
  t.passed.inc
  echo &"  PASS  {name}"

proc no*(t: var T, name, why: string) =
  t.lastOk = false
  if t.quiet: return
  t.failed.inc
  echo &"  FAIL  {name}\n        {why}"

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
  of vEmit:     @[tuckExe, "c", it.dir / "t.tuck", "-o:" & it.dir / "out",
                  "--root:" & t.root]
  of vEmitOdin: @[tuckExe, "c", it.dir / "t.tuck", "--odin",
                  "-o:" & it.dir / "odin", "--root:" & t.root]
  of vBuild:    @[tuckExe, "build", it.dir / "t.tuck", "-o:" & it.dir / "out",
                  "--root:" & t.root]
  of vRun:      @[it.dir / "out" / "t"]

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
    t.work.add WorkItem(dir: t.cur, verb: verb, dep: dep, rc: 0)
    result = t.work.high
    t.byKey[key] = result
  else:
    result = t.byKey[key]

proc item(t: T, idx: int): WorkItem = t.work[idx]

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

proc runs*(t: var T, name: string, code: int) =
  let b = t.need(vBuild)
  let r = t.need(vRun, dep = b)
  if t.phase == pCollect: return
  if t.failedTo(b):
    t.no name, "build failed: " & tailLines(t.item(b).output, 2)
    return
  let it = t.item(r)
  if it.rc == code: t.ok name
  else: t.no name, &"exit {it.rc}, want {code}: " & lastLine(it.output)

proc outputs*(t: var T, name, pattern: string) =
  ## Reads the run captured by the preceding `runs`. Registering the run here
  ## too would be wrong — `outputs` never builds on its own in lib.sh either.
  let r = t.need(vRun, dep = t.need(vBuild))
  if t.phase == pCollect: return
  if find(t.item(r).output, re(pattern)) >= 0: t.ok name
  else:
    t.no name, &"output did not match /{pattern}/: " & lastLine(t.item(r).output)

proc emittedNim(t: T, i: int): string =
  let p = t.item(i).dir / "out" / "t.nim"
  if fileExists(p): readFile(p) else: ""

proc emits*(t: var T, name, pattern: string) =
  ## A failed emit is reported AS a failed emit, not as a missing pattern —
  ## otherwise a test whose .tuck source stops compiling silently reads as
  ## "feature absent" forever.
  let i = t.need(vEmit)
  if t.phase == pCollect: return
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
  if t.failedTo(i):
    t.no name, "Odin emission failed: " & lastLine(t.item(i).output)
  elif find(t.emittedOdin(i), re(pattern)) >= 0:
    t.no name, &"emitted Odin contains /{pattern}/ but should not"
  else:
    t.ok name

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

proc unifiedDiff(want, got: string, ctx: int): string =
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

proc frozen*(t: var T, name: string) =
  let i = t.need(vEmit)
  if t.phase == pCollect: return
  if t.failedTo(i):
    t.no name, "emission failed: " & lastLine(t.item(i).output)
    return
  let dir = "tests/golden" / t.name
  let want = dir / (slugify(name) & ".nim")
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
  let got = keep.join("\n")
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
  if t.lastOk: t.ok name & " (regression guard)"
  else: t.no name, "REGRESSED — this was fixed and has come back"

proc bugOpen*(t: var T, name: string) =
  if t.phase == pCollect: return
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
                   prep: proc (dir: string) {.closure.}, dir: string): int =
  ## A command that depends on an earlier item AND needs files staged between
  ## the two. `prep` runs after `dep` succeeds and before this command starts.
  ##
  ## This exists for exactly one shape: `odin build` over a package assembled
  ## from a .odin the pool itself produced. Without the hook the staging would
  ## have to happen in the report pass, which is after every command has
  ## already run.
  let key = "cmd\0" & argv.join("\0")
  if t.phase == pCollect:
    if key in t.byKey: return t.byKey[key]
    t.work.add WorkItem(dir: dir, verb: vCheck, dep: dep, rc: 0)
    result = t.work.high
    t.byKey[key] = result
    t.rawCmds[result] = argv
    t.preps[result] = prep
  else:
    result = t.byKey[key]

proc needCmd*(t: var T, argv: seq[string]): int =
  ## Register an arbitrary command. Keyed by the command itself, since these
  ## are not tied to a snippet dir.
  let key = "cmd\0" & argv.join("\0")
  if t.phase == pCollect:
    if key in t.byKey: return t.byKey[key]
    t.work.add WorkItem(dir: "", verb: vCheck, dep: -1, rc: 0)
    result = t.work.high
    t.byKey[key] = result
    t.rawCmds[result] = argv
  else:
    result = t.byKey[key]

proc resultOf*(t: T, idx: int): (int, string) =
  (t.work[idx].rc, t.work[idx].output)

# --- suite lifecycle -----------------------------------------------------

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
  echo &"{t.name}.sh: {t.passed} passed, {t.failed} failed"
