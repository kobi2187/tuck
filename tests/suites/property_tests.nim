## `tuck test --properties` (issue #68): property tests generated from the
## program. The effect-free fns that return a type with an `invariant:` are
## called with generated integer/bool arguments; the invariant is the property.
## Builds a harness per target, so this is a build-level suite.

import std/[os, strutils]
import ../harness

proc run*(t: var T) =
  ## Registers the property-test assertions.
  t.src """
type Chunk:
  index: int
  first: int
  last: int
  have: int
  invariant:
    first <= last
    have >= 0
    have <= (last - first) + 1

fn spanOf({i: int, have: int}) -> Chunk:
  return {index: i, first: i, last: i + 5, have: have} Chunk

fn steady({a: int}) -> Chunk:
  return {index: 0, first: 0, last: 10, have: 3} Chunk

fn main() -> int:
  return 0
"""
  let run = t.needCmd(@["./tuck", "test", t.curDir / "t.tuck", "--properties",
                        "--cases:40", "--root:" & t.root], verb = vRun)
  if t.phase != pCollect:
    if t.wasSkipped(run): t.skip "a violated invariant is found and its input named"
    else:
      let (rc, outp) = t.resultOf(run)
      if rc == 0:
        t.no "a violated invariant is found and its input named",
             "expected a failure, got: " & outp
      elif "spanOf: FAILED on spanOf {" notin outp or
           "Invariant violated" notin outp:
        t.no "a violated invariant is found and its input named", outp
      elif "steady: 40 cases, Chunk invariant held" notin outp:
        t.no "a fn whose invariant holds passes", outp
      else:
        t.ok "a violated invariant is found and its input named"
        t.ok "a fn whose invariant holds passes"

  t.src """
fn main() -> int:
  return 0
"""
  let none = t.needCmd(@["./tuck", "test", t.curDir / "t.tuck", "--properties",
                         "--root:" & t.root])
  if t.phase != pCollect:
    let (rc, outp) = t.resultOf(none)
    if rc == 0 and "no property targets" in outp:
      t.ok "a program with no target says so and succeeds"
    else:
      t.no "a program with no target says so and succeeds", outp

  t.finish()
