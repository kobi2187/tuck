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

  # The three spellings are the SAME list, which an okCheck cannot show —
  # printing the values is what proves a newline separated rather than
  # silently dropped an element.
  t.src """
import seq
import str
import console

fn main() -> int [io]:
  let commas = [1, 2, 3]
  let breaks = [1
                2
                3]
  let lead = [ 1
             , 2
             , 3
             ]
  let a = {items: commas} count
  let b = {items: breaks} count
  let c = {items: lead} count
  {text: "n=" + a.toStr + b.toStr + c.toStr} printLine
  {text: "last=" + ({items: breaks, index: 2} at).toStr} printLine
  return 0
"""
  t.hostRuns "all three spellings build the same list", 0, "n=333"
  t.hostRuns "...and its elements are in order", 0, "last=3"

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

  # A line that ends OWING something continues — a trailing binary operator,
  # comma or `=` cannot end an expression, so the break is neither a
  # separator nor a terminator. Go's semicolon rule, ruled 2026-09-15 on the
  # grounds that wrapping a long expression is convenience rather than a
  # safety or maintainability question.
  #
  # Works OUTSIDE brackets too, which is the half bracketDepth cannot cover.
  t.src """
import seq
import str
import console

fn main() -> int [io]:
  let a = [1, 2, 3]
  let n = ({items: a} count) * 100 +
          ({items: a} count) * 10 +
          7
  let long = "alpha" +
             "beta" +
             "gamma"
  {text: "n=" + n.toStr +
         " " + long} printLine
  return 0
"""
  t.hostRuns "a trailing operator continues the line", 0, "n=337 alphabetagamma"

  # The set is deliberately small, and these are the measured reasons.
  # A trailing `:` OPENS a block: swallowing that newline left a fn body's
  # indent with nothing to attach to.
  t.src """
fn f() -> int:
  return 1

fn main() -> int:
  return {} f
"""
  t.okCheck "a trailing `:` still opens a block, not a continuation"

  # `...` ends in a dot, and six examples stopped parsing when tkDot was in
  # the set — the newline after a placeholder body disappeared.
  t.src """
fn f({n: int}) -> void:
  ...

fn main() -> int:
  return 0
"""
  t.okCheck "a `...` placeholder body still ends its line"

  t.finish()
