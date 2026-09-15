## Deliberate syntax ceilings — RULED 2026-08-19, documented, not bugs.
##
## Spike S-01 (DISCOVERIES.md) wrote a weekend-sized program and hit three
## parse walls. Two are real and were ruled as CEILINGS rather than gaps: the
## workaround is one `let`, and the parser stays simple, which is the
## reject-don't-transform rule applied to the front end (ROADMAP-GRAPH.md §0).
##
## This suite exists so the ceiling cannot move silently in either direction.
## If someone implements either form, these assertions fail and demand that
## LANGUAGE-OVERVIEW.md §0 rows 13 and 14 be updated in the same change — the
## same "one truth, two views" discipline the hole and bug counts already use.
##
## The third wall from S-01 was NOT a ceiling and no assertion belongs here:
## `{a: n twice} P` — a bare-receiver postfix call in a struct-literal field —
## checks clean. What failed in the spike was `f at 0`, a postfix call carrying
## an extra argument, which is not syntax in any position.

import ../harness

proc run*(t: var T) =
  # Ceiling 1 was LIFTED on 2026-09-15. A bracketed list wraps, and a line
  # break inside brackets separates exactly as a comma does — so the last
  # comma on a line is optional and the closing bracket may sit on its own.
  #
  # The ceiling's own rationale was "the workaround is one `let`". That holds
  # for a three-element list and stops holding for a payload of four fields,
  # which needs a `let` every time it is written; the web-downloader app had
  # to split three payloads for no reason a reader would recognise.
  #
  # Kept here rather than moved: this suite exists so a ruled position cannot
  # change in EITHER direction without the assertion and LANGUAGE-OVERVIEW
  # row 13 moving together, and that is what this commit does.
  t.src """
import seq

fn f() -> Seq[int]:
  [ 1
  , 2
  , 3
  ]
"""
  t.okCheck "a list literal wraps, with a leading comma"

  t.src """
import seq

fn f() -> Seq[int]:
  [1
   2
   3]
"""
  t.okCheck "...and with no comma at all — a newline separates"

  t.src """
import seq

fn f() -> Seq[int]:
  [1, 2,
   3]
"""
  t.okCheck "...and with a trailing comma before the break"

  # Ceiling 2 — a value-`if` is a whole right-hand side, never an operand.
  t.src """
fn f({hot: bool}) -> int:
  var t = 0
  t = t + if hot: 1 else: 2
  t
"""
  t.badCheck "a value-if is not an operand",
    "Expected an expression here, found `if`"

  # The documented workaround for ceiling 2 compiles — a ceiling with no way
  # around it would be a gap, so this is the half that makes the ruling honest.
  t.src """
fn f({hot: bool}) -> int:
  var t = 0
  let add = if hot: 1 else: 2
  t = t + add
  t
"""
  t.okCheck "binding the branch value first is the way around it"

  t.finish()
