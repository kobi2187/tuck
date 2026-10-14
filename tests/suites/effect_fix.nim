## Effect propagation tells the user what to write (issue #14).
##
## The ruling (2026-09-13) is that effects stay DECLARED in the code — reading
## a signature tells you at a glance what the body may do — and the compiler,
## which already works out what is required, says what to add or remove. So
## TK-EF01 points at the call that needs the effect and spells the fix, and
## TK-EF02 warns about a declared `[io]` nothing in the body needs.

import ../harness

proc run*(t: var T) =
  ## Registers the effect-guidance assertions.
  t.src """
import console

fn inner() -> void [io]:
  {text: "x"} printLine

fn outer() -> void:
  {} inner

fn main() -> int:
  {} outer
  return 0
"""
  t.badCheck "an undeclared effect is still an error (TK-EF01)", "TK-EF01"
  t.badCheck "...naming the call that needs it", "'inner' is \\[io\\]"
  t.badCheck "...and the fix: declare it on the fn it names",
             "Fix: declare \\[io\\] on 'outer'"
  t.badCheck "...reported at the call, not at the fn", "t\\.tuck:7:"

  t.src """
import console

fn inner() -> void [io]:
  {text: "x"} printLine

fn outer() -> void [io]:
  {} inner

fn main() -> int:
  {} outer
  return 0
"""
  t.okCheck "declared at every level, it checks clean"
  t.checkSilent "...and says nothing", "TK-EF0"

  t.src """
fn quiet({n: int}) -> int [io]:
  return n + 1

fn main() -> int:
  return {n: 1} quiet
"""
  t.checkSays "a declared [io] nothing needs is a warning (TK-EF02)",
              "Effect\\ Warning\\ \\[TK-EF02\\]"
  t.okCheck "...not an error: the build carries on"

  t.src """
fn later({n: int}) -> int [io]:
  ...

fn main() -> int:
  return 0
"""
  t.checkSilent "a `...` stub's bracket is its contract, so no warning", "TK-EF02"

  t.finish()
