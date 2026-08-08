## End-to-end guard for type-based field/param auto-matching.
##
## A typecheck-only test cannot catch a MISALIGNED mapping: if two fields have
## compatible types, binding the wrong one to the wrong param still typechecks
## cleanly and still emits well-formed Nim. Only running the code and checking
## the VALUES proves the mapping is right.
##
## Replaces tests/auto_alias_e2e.nim, which got the values out by emitting Nim
## and appending a hand-written Nim harness (`echo run()`) to inspect them.
## Here the Tuck program prints the string itself and `runs`/`outputs` check
## stdout — same assertion, no Nim harness and no compiler linked in.

import ../harness

proc run*(t: var T) =
  # The core correctness case: every field has a DISTINCT type and a
  # distinguishable value. A misaligned mapping still compiles, so only the
  # values can prove each param received the field intended for it.
  t.src """
import console

fn describe({id: int, name: str, ratio: float}) -> str:
  return name + "/" + id.toStr + "/" + ratio.toStr

fn main() -> void [io]:
  let ext = {title: "SlowJam", weight: 0.5, trackId: 42}
  {text: ext describe} console::printLine
"""
  t.runs    "distinct-types-map-correctly", 0
  t.outputs "distinct-types-map-correctly", "SlowJam/42/0\\.5"

  # Field ORDER in the source record is scrambled relative to param order:
  # auto-matching must key on type, never on position.
  t.src """
import console

fn join({first: str, second: int}) -> str:
  return first + "/" + second.toStr

fn main() -> void [io]:
  let r = {num: 7, word: "hello"}
  {text: r join} console::printLine
"""
  t.runs    "source-field-order-is-irrelevant", 0
  t.outputs "source-field-order-is-irrelevant", "hello/7"

  # Mixed: one param matched by NAME, the other by type. The name-matched field
  # must not be stolen by the type pass, and vice versa.
  t.src """
import console

fn join({count: int, label: str}) -> str:
  return label + "/" + count.toStr

fn main() -> void [io]:
  let r = {count: 3, heading: "Total"}
  {text: r join} console::printLine
"""
  t.runs    "name-match-and-type-match-together", 0
  t.outputs "name-match-and-type-match-together", "Total/3"

  # Two int fields, one matching a param by name. The name match must claim it,
  # leaving the OTHER int for the remaining int param — not the reverse. A
  # swapped mapping would print "n999/1" here and still compile fine.
  t.src """
import console

fn join({id: int, size: int}) -> str:
  return "n" + id.toStr + "/" + size.toStr

fn main() -> void [io]:
  let r = {id: 1, byteCount: 999}
  {text: r join} console::printLine
"""
  t.runs    "name-match-claims-its-field-before-type-pass", 0
  t.outputs "name-match-claims-its-field-before-type-pass", "n1/999"

  # Regression: explicit alias() must keep producing the correct assignment.
  t.src """
import console

fn describe({id: int, name: str, length: int}) -> str:
  return name + "/" + id.toStr + "/" + length.toStr

fn main() -> void [io]:
  let ext = {trackId: 42, title: "SlowJam", durationMs: 215000}
  let norm = ext alias(trackId: id, title: name, durationMs: length)
  {text: norm describe} console::printLine
"""
  t.runs    "explicit-alias-still-correct", 0
  t.outputs "explicit-alias-still-correct", "SlowJam/42/215000"

  t.finish()
