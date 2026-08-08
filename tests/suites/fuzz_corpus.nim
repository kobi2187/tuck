## Replay the fuzz corpus: every saved input must be handled, not crash.
##
## The corpus in fuzz/corpus/ is what a libFuzzer run discovered — inputs that
## reached new code paths in the lexer and parser. Most are malformed. The
## contract is not that they parse, it is that each one produces a DIAGNOSTIC
## rather than taking the compiler down.
##
## This is the cheap half of fuzzing: no libFuzzer, no sanitizers, no mutation
## — just the inputs a real run already found, replayed in a second. It catches
## the regression where a refactor reintroduces a crash on input that used to
## be handled cleanly.
##
## To grow the corpus, run the fuzzer (see fuzz/README.md) and commit whatever
## new inputs it saves.

import std/[os, algorithm, strutils]
import ../harness

proc run*(t: var T) =
  # `parse` rather than `check`: the corpus targets the FRONT END, and a
  # malformed file has nothing for the typechecker to say anyway.
  var files: seq[string]
  for d in ["fuzz/corpus", "fuzz/findings"]:
    for f in walkFiles(d / "*"):
      if fileExists(f): files.add f
  files.sort()

  var idx: seq[(string, int)]
  for f in files:
    idx.add (f, t.needCmd(@["./tuck", "parse", f]))

  if t.phase != pReport: return

  var pass = 0
  var fail = 0
  for (f, i) in idx:
    let (rc, raw) = t.resultOf(i)
    # Fuzz inputs contain NUL bytes, and they travel back through the captured
    # output; strip them so the report is readable.
    let outp = raw.replace("\0", "")
    # Exit 0 (parsed) and exit 1 (rejected with a diagnostic) are both correct.
    # Anything else — a signal, an unhandled Nim exception — is the failure.
    if rc != 0 and rc != 1:
      echo "  FAIL  " & f & " exited " & $rc
      for l in outp.splitLines()[0 ..< min(3, outp.splitLines().len)]:
        echo "        " & l
      fail.inc
    elif outp.contains("Error: unhandled exception") or
         outp.contains("SIGSEGV") or outp.contains("Traceback"):
      echo "  FAIL  " & f & " crashed rather than reporting"
      for l in outp.splitLines()[0 ..< min(3, outp.splitLines().len)]:
        echo "        " & l
      fail.inc
    else:
      pass.inc

  # This suite counts its own, rather than going through ok/no: it reports one
  # line per FAILURE and a total, not a line per corpus entry — 106 PASS lines
  # would bury everything else in the run.
  t.passed = pass
  t.failed = fail
  echo "fuzz_corpus.sh: " & $pass & " passed, " & $fail & " failed"
