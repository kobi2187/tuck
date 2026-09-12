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
## Usage: tools/doc_snippets [--list|--why]
##   --list  name the offenders
##   --why   name them AND print the diagnostic plus the block, which is what
##           you need to actually fix one
import os, osproc, strutils, re

proc main() =
  let root = getCurrentDir()
  let tuckExe = root / "tuck"
  var files: seq[string]
  for f in walkDirRec(root):
    if f.endsWith(".md") and "/.git/" notin f: files.add(f)
  var total, okCount, fragCount, badCount = 0
  var rejTotal, rejStale = 0
  var bad, why, stale: seq[string]
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
      elif "TK-PA03" in outp or "TK-PA09" in outp: fragCount.inc
      else:
        badCount.inc
        bad.add(f.relativePath(root) & ":" & $line)
        why.add(outp.strip() & "\n--- block ---\n" & body)
  if paramCount() > 0 and paramStr(1) == "--list":
    for b in bad: echo b
    for b in stale: echo b, "  (tuck-rejected, but it parses now)"
  elif paramCount() > 0 and paramStr(1) == "--why":
    for i, b in bad:
      echo "========== ", b
      echo why[i]
  for b in stale: echo b, ": tagged tuck-rejected, but it parses now"
  echo "tuck blocks: ", total, "  parse: ", okCount,
       "  fragments (TK-PA03/09): ", fragCount, "  REJECTED: ", badCount
  echo "tuck-rejected blocks: ", rejTotal, "  still rejected: ",
       rejTotal - rejStale, "  STALE (now parse): ", rejStale

main()
