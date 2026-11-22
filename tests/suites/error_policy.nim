## The error policy across modules (owner ruling 2026-11-22).
##
## `errors [policy: ...]` is the walking skeleton's switch: the stage of
## development stated in one place. The rule for any site:
##
##   in a FINISHED module (one declaring `errors [policy: strict]`): strict;
##   anywhere else: the ENTRY module's policy.
##
## So a partial library's dropped errors follow the application, reach the
## application's `on unhandled`, and are listed in its SHORTCUTS report; a
## finished library holds no stubs and imports only finished ones; and code
## reachable from an `[irq]` handler is strict and stub-free whatever the
## application chose. Before this, a library's shortcut sites appeared in no
## report, and a library could run its own handler unseen.

import ../harness

const PlainLib = """
fn risky({n: int}) -> !int [io]:
  if n > 0:
    return Error.bad
  return n

fn helper({n: int}) -> int [io]:
  {n: n} risky
  return 1
"""

proc run*(t: var T) =
  # --- a partial library follows the application ------------------------
  t.src """
import console
import plain

errors [policy: continue]:
  on unhandled({code: u16, site: str}) [io: console]:
    {text: "APP handler"} console::printLine

fn main() -> int [io]:
  return {n: 1} helper
"""
  t.addFile "plain.tuck", PlainLib
  t.checkSays "a partial library's shortcut is listed under its name",
              "SHORTCUTS \\(1 [^)]*\\):\\s+plain::!int at helper line 7"
  t.hostRuns "a partial library's error reaches the application's handler", 1,
             "APP handler"

  t.src """
import plain

fn main() -> int [io]:
  return {n: 1} helper
"""
  t.addFile "plain.tuck", PlainLib
  t.badCheck "a strict application makes a partial library's drop an error",
             "unhandled error result.*policy: strict"

  # --- a partial library's own block is inert when imported -------------
  t.src """
import console
import own

errors [policy: continue]:
  on unhandled({code: u16, site: str}) [io: console]:
    {text: "APP handler"} console::printLine

fn main() -> int [io]:
  return {n: 1} helper
"""
  t.addFile "own.tuck", """
import console

errors [policy: continue]:
  on unhandled({code: u16, site: str}) [io: console]:
    {text: "LIB handler"} console::printLine
""" & PlainLib
  t.checkSays "an imported library's own policy is reported inert",
              "POLICY \\(1 [^)]*\\):\\s+own: its own `errors \\[policy: continue\\]` is inert"
  t.hostRuns "...and its handler is not the one that runs", 1, "APP handler"

  # --- a finished library is outside the application's policy -----------
  t.src """
import fin

errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    let c = code

fn main() -> int [io]:
  return {n: 1} helper
"""
  t.addFile "fin.tuck", "errors [policy: strict]\n" & PlainLib
  t.badCheck "a finished library stays strict under a continue application",
             "unhandled error result.*policy: strict"

  t.src """
import fin

fn main() -> int:
  return {n: 1} done
"""
  t.addFile "fin.tuck", """
errors [policy: strict]

fn done({n: int}) -> int:
  return n

fn later({n: int}) -> int:
  ...
"""
  t.badCheck "a finished library holds no stubs", "TK-PO02.*later"

  t.src """
import fin

fn main() -> int:
  return {n: 8} quarter
"""
  t.addFile "fin.tuck", """
import part

errors [policy: strict]

fn quarter({n: int}) -> int:
  let h = {n: n} half
  return {n: h} half
"""
  t.addFile "part.tuck", """
fn half({n: int}) -> int:
  return n /i 2
"""
  t.badCheck "a finished library imports only finished ones",
             "TK-PO03.*imports 'part'"

  t.src """
import fin

fn main() -> int:
  return {n: 27} ninth
"""
  t.addFile "fin.tuck", """
import fin2

errors [policy: strict]

fn ninth({n: int}) -> int:
  let x = {n: n} third
  return {n: x} third
"""
  t.addFile "fin2.tuck", """
errors [policy: strict]

fn third({n: int}) -> int:
  return n /i 3
"""
  t.okCheck "a finished library may import a finished one"

  # --- interrupt code is always strict and complete ---------------------
  t.src """
errors [policy: continue]:
  on unhandled({code: u16, site: str}):
    let c = code

fn risky({n: int}) -> !int [io]:
  if n > 0:
    return Error.bad
  return n

fn isr() [irq, irq_safe, no_alloc, io]:
  {n: 1} risky
  return

fn main() -> int:
  return 0
"""
  t.badCheck "interrupt code may not leave an error to the policy",
             "TK-PO04.*interrupt handler 'isr'"

  t.src """
fn helper({n: int}) -> int [irq_safe, no_alloc]:
  ...

fn isr() [irq, irq_safe, no_alloc]:
  let x = {n: 1} helper
  return

fn main() -> int:
  return 0
"""
  t.badCheck "interrupt code may not call a stub", "TK-PO04.*'helper' is a stub"

  t.finish()
