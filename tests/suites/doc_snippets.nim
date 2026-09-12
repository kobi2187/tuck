## Every ```tuck block in the repo's markdown must parse, or be a fragment.
##
## The docs teach the language, so a block the parser rejects teaches syntax
## the compiler does not have — worse than an omission, because a reader
## cannot tell. Real instances: tuck-spec.md shows `poll()` where Tuck has no
## paren-call syntax at all, and TOUR.md shows `io::printLine` where `io` is
## now a reserved attribute name.
##
## Fragments are expected and not counted. The parser has a distinct code for
## each shape a doc legitimately shows:
##   TK-PA03  a top-level statement — an illustrative line, not a module
##   TK-PA09  a block opened with nothing inside — a signature shown alone
##
## A FRAGMENT IS CHECKED TO ITS LAST LINE. TK-PA03 stops the parser at the
## first top-level statement, so for 40 blocks everything after that line was
## never read — a cheat sheet showed five `for` headers and only the first was
## ever seen. The tool now re-parses the tail inside a generated `fn`; a block
## whose tail still fails is reported separately and must be zero.
##
## A ```tuck-rejected fence inverts the assertion. Some blocks show rejected
## code on purpose — a spec illustrating a compile error, a FRICTIONS entry
## recording what the language will not express, a ROADMAP sketch of syntax
## that does not exist yet. Those are checked in REVERSE: one that starts
## parsing fails the suite, which is how a roadmap item that quietly landed,
## or a friction that was quietly fixed, gets found.
##
## A RATCHET, like the complexity budget: the ceiling is whatever the tree has
## today and is lowered by hand, never raised.

import ../harness
import strutils

proc run*(t: var T) =
  # Lowered by hand as documents are reconciled against the compiler. Never
  # raise it: a new rejected block means a doc just gained syntax the language
  # does not have.
  const RejectedCeiling = 0

  let i = t.needCmd(@["./tools/doc_snippets"])
  if t.phase != pReport: return
  if t.skippedCmd(i):
    t.skip "documented Tuck parses (or is a fragment)"
    return
  let (rc, outp) = t.resultOf(i)
  if rc != 0:
    t.no "documented Tuck parses (or is a fragment)", outp.strip()
    return
  var rejected = -1
  for w in outp.split({' ', '\n'}):
    if rejected == -2: rejected = (try: parseInt(w) except: -1)
    if w == "REJECTED:": rejected = -2
  if rejected < 0:
    t.no "documented Tuck parses (or is a fragment)",
         "could not read the count from: " & outp.strip()
  elif rejected <= RejectedCeiling:
    t.ok "documented Tuck: " & $rejected & " rejected blocks, ceiling " &
         $RejectedCeiling
  else:
    t.no "documented Tuck: rejected blocks grew",
         $rejected & " rejected, ceiling " & $RejectedCeiling &
         " — run tools/doc_snippets --list"

  # Fragments whose tail the parser never reached.
  var loose = -1
  for w in outp.split({' ', '\n'}):
    if loose == -2: loose = (try: parseInt(w) except: -1)
    if w == "TAILS:": loose = -2
  if loose < 0:
    t.no "every fragment is checked to its last line",
         "could not read the unverified-tail count from: " & outp.strip()
  elif loose == 0:
    t.ok "every fragment is checked to its last line"
  else:
    t.no "every fragment is checked to its last line",
         $loose & " fragment(s) have an unparsed tail — " &
         "run tools/doc_snippets --why"

  # The inverted half. A tuck-rejected block that parses is a doc claiming the
  # compiler says no when it no longer does.
  var stale = -1
  for w in outp.split({' ', '\n'}):
    if stale == -2: stale = (try: parseInt(w) except: -1)
    if w == "STALE": stale = -3
    elif stale == -3 and w == "(now": stale = -3
    elif stale == -3 and w == "parse):": stale = -2
  if stale < 0:
    t.no "no tuck-rejected block has started parsing",
         "could not read the stale count from: " & outp.strip()
  elif stale == 0:
    t.ok "no tuck-rejected block has started parsing"
  else:
    t.no "no tuck-rejected block has started parsing",
         $stale & " now parse — the doc says the compiler rejects them; " &
         "run tools/doc_snippets --list"
