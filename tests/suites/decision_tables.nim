## Decision tables are LOWERED (ROADMAP M4.2), not built by the emitters.
##
## `lowering_decisions` turns a table into an ordinary body before any backend
## sees it: a `match` over a packed integer key when every column is
## enumerable, an `if` chain ending in the catch-all row otherwise. The three
## emitters used to build the table themselves and had drifted — D packed a
## table of any size where Nim and Odin fell back to a chain above 4096
## combinations. What a backend still spells its own way is the ORDINAL of an
## enum or bool (`exkOrdinal`), and that is asserted here per backend.
##
## Every runtime assertion is `hostRuns`: the same program, the same answer,
## on all three.

import ../harness

proc run*(t: var T) =
  # --- packed: every column enumerable ---------------------------------------
  #
  # Eight combinations, three outcomes, first match wins: `High _ true` is
  # listed before `High _ false`, and the `big` column only matters for Low.
  # Each combination's answer is folded into one number, so a single wrong
  # combination anywhere changes the printed result.
  t.src """
import console
import str

type Priority:
  | High
  | Low

type Action:
  | Secure
  | Fast
  | Now

decision classify({priority: Priority, big: bool, encrypted: bool}) -> Action:
  | High  _     true  -> Secure
  | High  _     false -> Fast
  | Low   true  _     -> Now
  | Low   false _     -> Fast

fn code({a: Action}) -> int:
  match a:
    Secure: return 1
    Fast: return 2
    Now: return 3

fn one({p: Priority, b: bool, e: bool}) -> int:
  let a = {priority: p, big: b, encrypted: e} classify
  return {a: a} code

fn main() -> int [io]:
  var n = 0
  n = n * 4 + {p: High, b: false, e: false} one
  n = n * 4 + {p: High, b: false, e: true} one
  n = n * 4 + {p: High, b: true, e: false} one
  n = n * 4 + {p: High, b: true, e: true} one
  n = n * 4 + {p: Low, b: false, e: false} one
  n = n * 4 + {p: Low, b: false, e: true} one
  n = n * 4 + {p: Low, b: true, e: false} one
  n = n * 4 + {p: Low, b: true, e: true} one
  {text: n.toStr} printLine
  return 0
"""
  # 2,1,2,1 then 2,2,3,3 in base 4: 0b10_01_10_01_10_10_11_11 = 39343.
  t.hostRuns "packed: every combination answers its first matching row", 0,
             "39343"
  t.emits "packed: Nim spells the ordinal ord()", r"ord\(priority\)"
  t.emitsOdin "packed: Odin spells an enum's ordinal int()", r"int\(priority\)"
  t.emitsOdin "packed: ...and a bool's as a ternary", r"\(encrypted \? 1 : 0\)"
  t.emitsD "packed: D spells the ordinal as a cast", r"cast\(long\)\(priority\)"
  t.emits "packed: combinations with one outcome share an arm",
          r"of \d+, \d+"
  t.omits "packed: no comparison chain", r"elif"

  # --- chained: an open column ----------------------------------------------
  #
  # An int column cannot be enumerated, so the rows become guards in order
  # and the table must end in a catch-all (the checker demands it).
  t.src """
import console
import str

decision fee({units: int, member: bool}) -> int:
  | 0  _     -> 0
  | 1  true  -> 5
  | 1  false -> 7
  | _  true  -> 9
  | _  _     -> 11

fn main() -> int [io]:
  var n = 0
  n = n * 16 + {units: 0, member: false} fee
  n = n * 16 + {units: 1, member: true} fee
  n = n * 16 + {units: 1, member: false} fee
  n = n * 16 + {units: 2, member: true} fee
  n = n * 16 + {units: 3, member: false} fee
  {text: n.toStr} printLine
  return 0
"""
  # 0,5,7,9,11 in base 16: 0x0579B = 22427.
  t.hostRuns "chained: rows fire in order, the catch-all last", 0, "22427"
  t.omitsOdin "chained: an open column is never packed", r"switch"

  # --- one outcome ----------------------------------------------------------
  #
  # Every combination answers the same: there is nothing to dispatch on, and
  # the lowered body is a bare return rather than a match with one arm.
  t.src """
decision always({a: bool}) -> int:
  | true  -> 4
  | false -> 4

fn main() -> int:
  return {a: true} always
"""
  t.hostRuns "one outcome: the table is a plain return", 4
  t.omits "one outcome: no case at all", r"case"

  # --- a table called from above its declaration ------------------------------
  #
  # A lowered table is an ordinary fn, so the Nim backend now gives it a
  # forward declaration like any other (its own emitter wrote a header of its
  # own and was skipped there). Nim's code reordering already carried this
  # simple shape; the assertion is that the change keeps it working.
  t.src """
fn main() -> int:
  return {a: false} pick

decision pick({a: bool}) -> int:
  | true  -> 1
  | false -> 6
"""
  t.hostRuns "a table is callable from a fn declared above it", 6
