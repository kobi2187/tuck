## Every ```tuck block in the repo's markdown, parsed.
##
## The docs teach the language; a block that does not parse teaches syntax the
## compiler rejects. That is worse than an omission, because a reader has no
## way to tell — and it has happened: the spec shows `poll()` where Tuck has
## no paren-call syntax at all, and TOUR.md shows `io::printLine` where `io`
## is now a reserved attribute name.
##
## TWO FAILURES ARE EXPECTED AND NOT COUNTED. A doc legitimately shows
## fragments, and the parser has a distinct code for each shape:
##   TK-PA03  a top-level statement — an illustrative line, not a module
##   TK-PA09  a block opened with nothing inside — a signature shown alone
## Anything else is the doc claiming syntax the language does not have.
##
## A ```tuck-rejected FENCE INVERTS THE ASSERTION. Some blocks show rejected
## code on purpose: a spec illustrating a compile error, a FRICTIONS entry
## recording what the language will not express, a ROADMAP sketch of syntax
## that does not exist yet. Those must not be "fixed" into valid code — the
## rejection IS the claim. Tagged this way they are checked in reverse: a
## tuck-rejected block that starts parsing fails, which is how a roadmap item
## that quietly landed, or a friction that was quietly fixed, gets found.
##
## IT ALSO CHECKS PATH CITATIONS. A doc that points at `tools/cc.nim` after
## the file became `tools/cyc.nim` sends the reader nowhere, and nothing else
## notices. Every `tests/suites/…`, `examples/…`, `std/…`, `compiler/…`,
## `tools/…` and `benches/…` path mentioned in markdown must exist.
##
## Dated records are exempt: `thoughts/` and `docs/superpowers/` hold handoffs
## and plans that describe the tree as it was on a date. Updating those would
## falsify the record, which is the opposite of accuracy.
##
## Usage: tools/doc_snippets [--list|--why]
##   --list  name the offenders
##   --why   name them AND print the diagnostic plus the block, which is what
##           you need to actually fix one
import os, osproc, strutils, re

proc main() =
  let root = getCurrentDir()
  let tuckExe = root / "tuck"
  var files: seq[string]
  # `.claude/worktrees/` holds full checkouts of this repo, so walking into one
  # counts every doc a second time and reports its path citations as dead —
  # they resolve against the worktree root, not this one. A worktree is
  # present whenever an agent is mid-task, which made the suite fail for a
  # reason that had nothing to do with the docs.
  for f in walkDirRec(root):
    if not f.endsWith(".md"): continue
    if "/.git/" in f or "/.claude/" in f: continue
    files.add(f)
  var total, okCount, fragCount, badCount = 0
  var rejTotal, rejStale = 0
  var pa03, pa09, unverified = 0
  var bad, why, stale, loose: seq[string]
  let tmp = getTempDir() / "tuckdocsnip"
  createDir(tmp)
  # The fence's own indentation is markdown structure, not Tuck: a block
  # inside a list item is indented to stay in that item. Strip exactly the
  # fence's indent from every line, so a legitimately nested block is read at
  # column 0 while a block whose CONTENT is misindented still fails.
  let blockRe = re(r"```tuck(-rejected)?\n(.*?)```", {reDotAll})
  for f in files:
    let text = readFile(f)
    var start = 0
    while true:
      let bounds = text.findBounds(blockRe, start)
      if bounds.first < 0: break
      var matches: array[2, string]
      discard text.find(blockRe, matches, bounds.first)
      let line = text[0 ..< bounds.first].count('\n') + 1
      # Everything between the previous newline and the fence is the fence's
      # own indentation — markdown structure, not Tuck. Strip exactly that
      # much from each line, so a block nested in a list item is read at
      # column 0 while a block whose CONTENT is misindented still fails.
      let lineStart = text.rfind('\n', last = bounds.first) + 1
      let pad = text[lineStart ..< bounds.first]
      var body = ""
      for ln in matches[1].splitLines(true):
        body.add(if pad.len > 0 and ln.startsWith(pad): ln[pad.len .. ^1] else: ln)
      let snip = tmp / "snippet.tuck"
      writeFile(snip, body)
      let (outp, rc) = execCmdEx(tuckExe & " p " & snip & " 2>&1")
      # Advance FIRST: the rejected branch below `continue`s, and skipping
      # this line once meant scanning the same block forever.
      start = bounds.last + 1
      if matches[0] == "-rejected":
        # Inverted: this block claims the compiler says no.
        rejTotal.inc
        if rc == 0:
          rejStale.inc
          stale.add(f.relativePath(root) & ":" & $line)
        continue
      total.inc
      if rc == 0: okCount.inc
      elif "TK-PA03" in outp:
        # A top-level statement stops the parser at the FIRST such line, so
        # everything after it went unread — 40 blocks were "fragments" with
        # an unchecked tail. Wrap the block in a function and parse again:
        # if that succeeds every line has been seen. If it does not, the
        # block mixes declarations with statements (legitimate) or the tail
        # is wrong (not), so it is listed rather than counted as verified.
        # TK-PA03 names the line it stopped on. Everything before it is
        # declarations that already parsed, so only the tail from that line
        # needs a function around it. Wrapping the whole block instead would
        # fail on the leading `type`/`fn` and hide the real tail errors.
        var at = 0
        for part in outp.split({' ', ','}):
          if at == -1: at = (try: parseInt(part) except: 0); break
          if part == "line": at = -1
        if at <= 0: at = 1
        var wrapped = ""
        let lines = body.splitLines()
        for i, ln in lines:
          if i < at - 1: wrapped.add(ln & "\n")
        wrapped.add("\nfn tuckDocFragment() -> void:\n")
        for i, ln in lines:
          if i >= at - 1:
            wrapped.add(if ln.len == 0: "\n" else: "  " & ln & "\n")
        writeFile(snip, wrapped)
        let (wOut, wRc) = execCmdEx(tuckExe & " p " & snip & " 2>&1")
        if wRc == 0:
          pa03.inc
          fragCount.inc
        else:
          unverified.inc
          loose.add(f.relativePath(root) & ":" & $line)
          why.add("fragment tail unverified (TK-PA03, and wrapping it in a " &
                  "fn gives)\n" & wOut.strip() & "\n--- block ---\n" & body)
      elif "TK-PA09" in outp: pa09.inc; fragCount.inc
      else:
        badCount.inc
        bad.add(f.relativePath(root) & ":" & $line)
        why.add(outp.strip() & "\n--- block ---\n" & body)
  # --- path citations -----------------------------------------------------
  var deadPaths: seq[string]
  # The lookbehind matters: without it `modules/std/db/API.tuck.md` matches as
  # a citation of `std/db/API.tuck`, which does not exist. `std/` is left out
  # of the prefix list on purpose — it collides with Nim's own `std/` imports.
  let pathRe = re(r"(?<![\w./-])(tests/suites/|examples/|compiler/|tools/|benches/)[\w./-]*\.(nim|tuck|sh|odin|d|md)")
  for f in files:
    let rel = f.relativePath(root)
    if rel.startsWith("thoughts/") or rel.startsWith("docs/superpowers/"):
      continue
    var lineNo = 0
    for line in readFile(f).splitLines():
      inc lineNo
      # A FORWARD REFERENCE IS NOT A DEAD LINK. An unchecked task box names
      # the file the task will create, and "a new X.nim" says so in words.
      # Both are plans; only a path presented as existing has to exist.
      if "- [ ]" in line: continue
      var at = 0
      while true:
        let b = line.findBounds(pathRe, at)
        if b.first < 0: break
        let cited = line[b.first .. b.last]
        let before = line[0 ..< b.first]
        if not before.endsWith("new `") and not before.endsWith("new ") and
           not fileExists(root / cited):
          deadPaths.add(rel & ":" & $lineNo & " -> " & cited)
        at = b.last + 1

  if paramCount() > 0 and paramStr(1) == "--list":
    for b in bad: echo b
    for b in stale: echo b, "  (tuck-rejected, but it parses now)"
    for b in loose: echo b, "  (fragment tail unverified)"
    for b in deadPaths: echo b
  elif paramCount() > 0 and paramStr(1) == "--why":
    for i, b in bad & loose:
      echo "========== ", b
      echo why[i]
  for b in stale: echo b, ": tagged tuck-rejected, but it parses now"
  for b in deadPaths: echo b, ": cited path does not exist"
  echo "tuck blocks: ", total, "  parse: ", okCount,
       "  fragments (TK-PA03/09): ", fragCount, "  REJECTED: ", badCount
  echo "  of the fragments: TK-PA03 ", pa03, ", TK-PA09 ", pa09,
       "  UNVERIFIED TAILS: ", unverified
  echo "tuck-rejected blocks: ", rejTotal, "  still rejected: ",
       rejTotal - rejStale, "  STALE (now parse): ", rejStale
  echo "DEAD PATH CITATIONS: ", deadPaths.len

main()
