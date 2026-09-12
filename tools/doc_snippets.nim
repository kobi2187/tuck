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
## Usage: tools/doc_snippets [--list]
import os, osproc, strutils, re

proc main() =
  let root = getCurrentDir()
  let tuckExe = root / "tuck"
  var files: seq[string]
  for f in walkDirRec(root):
    if f.endsWith(".md") and "/.git/" notin f: files.add(f)
  var total, okCount, fragCount, badCount = 0
  var bad: seq[string]
  let tmp = getTempDir() / "tuckdocsnip"
  createDir(tmp)
  let blockRe = re(r"```tuck\n(.*?)```", {reDotAll})
  for f in files:
    let text = readFile(f)
    var start = 0
    while true:
      let bounds = text.findBounds(blockRe, start)
      if bounds.first < 0: break
      var matches: array[1, string]
      discard text.find(blockRe, matches, bounds.first)
      let line = text[0 ..< bounds.first].count('\n') + 1
      let snip = tmp / "snippet.tuck"
      writeFile(snip, matches[0])
      total.inc
      let (outp, rc) = execCmdEx(tuckExe & " p " & snip & " 2>&1")
      if rc == 0: okCount.inc
      elif "TK-PA03" in outp or "TK-PA09" in outp: fragCount.inc
      else:
        badCount.inc
        bad.add(f.relativePath(root) & ":" & $line)
      start = bounds.last + 1
  if paramCount() > 0 and paramStr(1) == "--list":
    for b in bad: echo b
  echo "tuck blocks: ", total, "  parse: ", okCount,
       "  fragments (TK-PA03/09): ", fragCount, "  REJECTED: ", badCount

main()
