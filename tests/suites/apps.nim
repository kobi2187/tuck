## Weekend programs, the kind a Python or Ruby user writes on day one: built
## against `--stdlib:stdlib-project` and RUN on Nim, Odin and D with fixed
## arguments and stdin, their stdout and exit code compared exactly.
##
## Each program lives in `stdlib-project/apps/<dir>/`. A case is one run; a
## program is built once per backend and every case of it runs against that
## build. Programs that use randomness take `--seed N`, so a run replays.

import std/[os, strutils]
import ../harness

type AppCase = tuple
  dir, file, args, input, want: string
  code: int

const Cases: seq[AppCase] = @[
  ("cli-hangman", "hangman", "--seed 2", "t\nu\nz\nc\nk\n",
   "Word: ____   Lives: 6\nWord: t___   Lives: 6\nWord: tu__   Lives: 6\n" &
   "Word: tu__   Lives: 5\nWord: tuc_   Lives: 5\nWord: tuck   Lives: 5\nYou win!\n", 0),
  ("cli-hangman", "hangman", "--seed 2", "a\nb\nd\nf\ng\nh\n",
   "Word: ____   Lives: 6\nWord: ____   Lives: 5\nWord: ____   Lives: 4\n" &
   "Word: ____   Lives: 3\nWord: ____   Lives: 2\nWord: ____   Lives: 1\n" &
   "Word: ____   Lives: 0\nYou lose. The word was: tuck\n", 1),
  # no newline after the last guess: still a line (A86)
  ("cli-hangman", "hangman", "--seed 2", "t\nu\nc\nk",
   "Word: ____   Lives: 6\nWord: t___   Lives: 6\nWord: tu__   Lives: 6\n" &
   "Word: tuc_   Lives: 6\nWord: tuck   Lives: 6\nYou win!\n", 0),
]

type Backend = tuple[label, flag, suffix: string]

proc backends(): seq[Backend] =
  result = @[("Nim", "", ""), ("Odin", "--odin", "_odin")]
  if findDmd().len > 0: result.add ("D", "--dlang", "_d")

proc buildDir(t: T, c: AppCase, b: Backend): string =
  t.curDir / (c.dir & "-" & b.label)

proc run*(t: var T) =
  ## Registers one build per program and backend, and one run per case.
  t.src "fn main() -> int:\n  return 0\n"
  let tuck = absolutePath(tuckExe)
  var builds: seq[tuple[key: string, idx: int]]
  var runs: seq[tuple[c: AppCase, b: Backend, idx: int]]
  for c in Cases:
    for b in backends():
      let dir = t.buildDir(c, b)
      let key = dir
      var bIdx = -1
      for (k, i) in builds:
        if k == key: bIdx = i
      if bIdx < 0:
        let src = t.root / "stdlib-project" / "apps" / c.dir
        let dmdPath = if b.label == "D": "PATH=" & parentDir(findDmd()) & ":$PATH " else: ""
        bIdx = t.needCmd(@["sh", "-c", "mkdir -p " & dir & " && cp -r " & src & "/. " &
            dir & " && cd " & dir & " && " & dmdPath & tuck & " b " & c.file &
            ".tuck " & b.flag & " --stdlib:stdlib-project --root:" & t.root &
            " > build.log 2>&1"], verb = vBuild)
        builds.add (key, bIdx)
      let cmd = "cd " & dir & " && printf %s " & quoteShell(c.input) & " | ./" &
                c.file & b.suffix & " " & c.args
      runs.add (c, b, t.needCmdAfter(@["sh", "-c", cmd], bIdx,
                                     proc (d: string) = discard, dir, verb = vRun))
  if t.phase == pCollect: return
  for (c, b, idx) in runs:
    let title = c.dir & " " & c.args & " on " & b.label
    if t.skippedCmd(idx): t.skip title; continue
    let (rc, outp) = t.resultOf(idx)
    if rc == c.code and outp == c.want: t.ok title
    else:
      t.no title, "exit " & $rc & " (want " & $c.code & ")\n--- got\n" & outp &
                  "--- want\n" & c.want
  t.finish()
