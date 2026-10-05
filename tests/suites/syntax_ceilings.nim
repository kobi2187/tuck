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
  ## Registers the deliberate syntax ceilings: each refused with the
  ## diagnostic that names the ruling.
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

  # R3, ruled 2026-09-28: a one-line `if c: s1 else: s2` whose branches are
  # STATEMENTS is the statement `if`. It checked and built on no backend — a
  # bare expression at column 0 on Nim, a ternary of assignments on Odin and
  # D. An assignment, a `return` and an `elif` chain; the value form beside
  # them still a value. step 3 -> 4, step 10 -> 0, sign -> 1, band -> 2,
  # pick -> 4: 4 + 0*50 + 1*10 + 2*20 + 4*30.
  t.src """
fn step({n: int}) -> int:
  var m = n
  if m > 9: m = 0 else: m = m + 1
  return m

fn sign({n: int}) -> int:
  if n < 0: return 1 else: return 2

fn band({n: int}) -> int:
  var b = 0
  if n < 10: b = 1 elif n < 100: b = 2 else: b = 3
  return b

fn pick({n: int}) -> int:
  let k = if n > 9: 0 else: n + 1
  return k

fn main() -> int:
  let a = {n: 3} step
  let b = {n: 10} step
  let c = {n: -4} sign
  let d = {n: 50} band
  let e = {n: 3} pick
  return a + b * 50 + c * 10 + d * 20 + e * 30
"""
  t.hostRuns "a one-line if with statement branches is the statement if (R3)", 174

  # ...and one whose branches are VOID CALLS: syntactically expressions, so
  # the type says it (lowering.blockVoidIf).
  t.src """
import console

fn hi() [io]:
  {text: "hi"} printLine

fn lo() [io]:
  {text: "lo"} printLine

fn main() -> int [io]:
  let n = 3
  if n > 2: {} hi else: {} lo
  return 0
"""
  t.hostRuns "a one-line if over void calls is a statement, on every backend", 0, "hi"

  t.finish()
