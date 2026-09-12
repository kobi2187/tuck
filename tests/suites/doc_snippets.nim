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
## A RATCHET, like the complexity budget: the ceiling is whatever the tree has
## today and is lowered by hand, never raised. Fixing docs is a separate,
## larger job (TODO backlog); this stops the number growing while it waits.

import ../harness
import strutils

proc run*(t: var T) =
  # Lowered by hand as documents are reconciled against the compiler. Never
  # raise it: a new rejected block means a doc just gained syntax the language
  # does not have.
  const RejectedCeiling = 53

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
