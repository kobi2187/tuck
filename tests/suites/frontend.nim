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

  # String escapes (issue #25). The lexer DECODES them, so the token carries
  # real characters, and each backend re-escapes on the way out via the one
  # shared resolution.escapeStringLit.
  #
  # Before this, an embedded quote was a lexical error ("Unexpected
  # character") and every OTHER backslash was passed through raw — so a `\n`
  # reached each host as the two characters `\` and `n`, which Nim, Odin and D
  # all happen to read as a newline. The feature half-worked by way of the
  # target language, undocumented and unchecked.
  t.src """
import console

fn main() -> int [io]:
  {text: "say \"hi\""} printLine
  return 0
"""
  t.outputs "an embedded quote survives to stdout", "say\\ .hi."
  t.hostBuilds "...on every backend"

  t.src """
import console

fn main() -> int [io]:
  {text: "a\nb"} printLine
  {text: "tab\there"} printLine
  {text: "back\\slash"} printLine
  return 0
"""
  t.outputs "newline, tab and backslash all decode", "back.slash"
  t.hostBuilds "...on every backend"

  # Rejected, not passed through: an escape Tuck does not define would
  # otherwise mean whatever the backend's own language says.
  t.src """
fn main() -> int:
  let s = "oops \q"
  return 0
"""
  t.badCheck "an undefined escape is refused", "TK-LX07"
  t.badCheck "...naming the whole set", "Tuck\\ defines"

  t.finish()
