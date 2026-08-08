## Lexer + parser smoke over every example.
##
## Replaces tests/lexer_examples.nim and tests/parser_examples.nim, which
## printed every token / decl of every example and only actually FAILED when
## the lexer or parser crashed. That is what this checks, without linking the
## compiler into two more Nim programs: `tuck l` and `tuck p` exit nonzero on
## a crash, which is the whole assertion.
##
## Note both verbs are single-FILE (no import resolution), so an example that
## imports a missing module still lexes and parses fine here — resolution is
## tests/examples.sh's job via `tuck ch`.

import std/[os, algorithm, strutils]
import ../harness

proc run*(t: var T) =
  var files: seq[string]
  for f in walkFiles("examples/*.tuck"): files.add f
  sort(files)

  var lexIdx, parseIdx: seq[(string, int)]
  for f in files:
    let name = f.extractFilename.changeFileExt("")
    lexIdx.add (name, t.needCmd(@["./tuck", "l", f]))
  for f in files:
    let name = f.extractFilename.changeFileExt("")
    parseIdx.add (name, t.needCmd(@["./tuck", "p", f]))

  if t.phase == pReport:
    for (name, i) in lexIdx:
      let (rc, outp) = t.resultOf(i)
      if rc == 0: t.ok "lex   " & name
      else: t.no "lex   " & name, "lexer failed: " & outp.strip(leading = false).splitLines()[^1]
    for (name, i) in parseIdx:
      let (rc, outp) = t.resultOf(i)
      if rc == 0: t.ok "parse " & name
      else: t.no "parse " & name, "parser failed: " & outp.strip(leading = false).splitLines()[^1]

  t.finish()
